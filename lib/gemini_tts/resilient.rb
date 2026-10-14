module GeminiTTS
  # Wraps a Client with the recovery behavior long-form generation needs:
  #
  # - Transient errors: rate limits back off exponentially; server and network
  #   errors retry after a pause.
  # - No-audio (3.1 and earlier only): the model intermittently returns text
  #   instead of audio, and re-sending the identical prompt tends to repeat the
  #   failure, so each retry perturbs the prompt without changing delivery: a
  #   delivery-neutral `[tag]` on the text, a `(take N)` nonce on the style, and
  #   a punctuation swap. Inputs under SHORT_INPUT_THRESHOLD characters fail
  #   almost always when sent clean, so they carry a neutral tag from the first
  #   attempt.
  # - Truncation: a take cut off mid-utterance (non-STOP finishReason, or audio
  #   that ends abruptly) is regenerated; the first clean retake wins, else the
  #   longest take is kept and flagged.
  #
  # 3.8 models read the text verbatim, so they get none of the prompt
  # perturbation: a no-audio fails at once, and retakes re-send the text
  # unchanged. (We haven't seen 3.8 need the workarounds; it fails fast so a
  # need would show up.)
  #
  # Content blocks and bad requests are never retried: they're deterministic.
  class Resilient
    DEFAULT_NO_AUDIO_ATTEMPTS = 6
    DEFAULT_MAX_ATTEMPTS = 3
    DEFAULT_TRUNCATION_RETAKES = 2
    SHORT_INPUT_THRESHOLD = 25

    # Delivery-NEUTRAL audio tags (3.1 reads `[...]` as a tag, so it's consumed,
    # not spoken). Prepending one changes the prompt enough to force a fresh
    # decode without measurably changing the output. Ordered by increasing
    # length; one per attempt. Needs at least DEFAULT_NO_AUDIO_ATTEMPTS entries:
    # a short input is tagged on every attempt.
    NEUTRAL_TAGS = [
      '[steadily]',
      '[in a clear voice]',
      '[narrated plainly]',
      '[without changing their tone of voice]',
      '[reading calmly, clearly, and without affect]',
      '[in an even, unhurried voice]'
    ].freeze

    # The outcome of a resilient generation. `result` is the kept take; `cost` is
    # the USD total of every billed request (retakes included; nil when
    # unpriced); `truncated` is true when even the kept take looks cut off.
    Take = Struct.new(:result, :cost, :truncated, keyword_init: true) do
      def truncated?
        truncated
      end
    end

    # `log` receives one progress line at a time (retries, retakes). `sleeper` is
    # injectable so tests don't wait.
    def initialize(client, no_audio_attempts: DEFAULT_NO_AUDIO_ATTEMPTS, max_attempts: DEFAULT_MAX_ATTEMPTS,
                   truncation_retakes: DEFAULT_TRUNCATION_RETAKES, log: nil, sleeper: ->(s) { sleep s })
      @client = client
      @no_audio_attempts = no_audio_attempts
      @max_attempts = max_attempts
      @truncation_retakes = truncation_retakes
      @log = log || ->(_line) {}
      @sleeper = sleeper
    end

    # Same arguments as Client#generate. Returns a Take, or raises the last
    # GeminiTTS::Error once retries are exhausted.
    def generate(text, voice:, model: nil, style: nil)
      model ||= @client.default_model
      legacy = !GeminiTTS.transcript_model?(model)
      short = legacy && text.length < SHORT_INPUT_THRESHOLD
      @log.call('short input; seeding with a neutral tag') if short

      tag_step = short ? 0 : nil # nil = no neutral tag (clean attempt)
      nonce = 0                  # 0 = unperturbed style
      punct_step = 0
      attempts = 0
      no_audio = 0

      begin
        attempt_text = self.class.perturb_punctuation(self.class.apply_tag(text, tag_step), punct_step)
        attempt_style = nonce.positive? ? self.class.perturb_style(style, nonce) : style
        result = @client.generate(attempt_text, voice: voice, model: model, style: attempt_style)
      rescue NoAudioError
        no_audio += 1
        unless legacy
          @log.call("no audio from #{model}; not retried (no cache-busting for this model)")
          raise
        end
        if no_audio >= @no_audio_attempts
          @log.call("no audio after #{no_audio} attempt(s); giving up")
          raise
        end
        # Short inputs already carry tag 0; escalate from there. Long inputs were
        # clean on attempt 0, so their first retry starts at tag 0.
        tag_step = short ? no_audio : no_audio - 1
        nonce = no_audio
        punct_step += 1
        @log.call("no audio; cache-busting retry #{no_audio}/#{@no_audio_attempts - 1} " \
                  "(tag #{self.class.tag_for(tag_step)} + style nonce + punct)")
        retry
      rescue RateLimitedError
        attempts += 1
        raise if attempts >= @max_attempts

        backoff = 2**attempts
        @log.call("rate limited; backing off #{backoff}s (attempt #{attempts + 1}/#{@max_attempts})")
        @sleeper.call(backoff)
        retry
      rescue ServerError, NetworkError => e
        attempts += 1
        raise if attempts >= @max_attempts

        @log.call("#{e.class.name.split('::').last}: #{e.message.lines.first.to_s.strip}; " \
                  "retrying (attempt #{attempts + 1}/#{@max_attempts})")
        @sleeper.call(1)
        retry
      end

      recover_truncation(result, text, voice: voice, model: model, style: style,
                                       tag_step: tag_step, legacy: legacy)
    end

    # Exposed for callers that want the same perturbations elsewhere.

    # Apply the neutral tag at `step` (or none when step is nil). If `text`
    # already starts with a tag, merge into one bracket group:
    # `[excited] Wow!` => `[steadily; excited] Wow!`.
    def self.apply_tag(text, step)
      return text if step.nil?

      inner = tag_for(step).delete_prefix('[').delete_suffix(']')
      if text =~ /\A\[([^\]]*)\]\s*(.*)\z/m
        "[#{inner}; #{Regexp.last_match(1)}] #{Regexp.last_match(2)}"
      else
        "#{tag_for(step)} #{text}"
      end
    end

    def self.tag_for(step)
      NEUTRAL_TAGS[step % NEUTRAL_TAGS.size]
    end

    # Append an inert "(take N)" nonce to the style: it changes the prompt enough
    # to force a new draw without being a directive. No-op without a style. `step`
    # is 1-based, so the first retry reads "(take 2)".
    def self.perturb_style(style, step)
      return style if style.to_s.strip.empty?

      "#{style.to_s.rstrip}\n\n(take #{step + 1})"
    end

    # Swap up to `step` punctuation marks for semicolons (each step swaps one `.`,
    # else one `,`), perturbing the input without changing pronunciation.
    def self.perturb_punctuation(text, step)
      return text if step < 1

      result = text.dup
      step.times do
        idx = result.index('.') || result.index(',')
        break unless idx

        result[idx] = ';'
      end
      result
    end

    private

    def recover_truncation(result, text, voice:, model:, style:, tag_step:, legacy:)
      cost = result.cost
      reason = result.truncation_reason
      return Take.new(result: result, cost: cost, truncated: false) unless reason

      @log.call("truncation detected (#{reason}); regenerating (up to #{@truncation_retakes} retake(s))")
      best = result
      step = tag_step

      @truncation_retakes.times do |i|
        step = step.nil? ? 0 : step + 1
        begin
          # 3.8 would speak a neutral tag, so its retakes re-send the text unchanged.
          cand = @client.generate(legacy ? self.class.apply_tag(text, step) : text, voice: voice, model: model, style: style)
        rescue Error => e
          @log.call("retake #{i + 1} failed (#{e.class.name.split('::').last}); keeping best so far")
          break
        end

        c = cand.cost
        cost = (cost || 0.0) + c if c
        cand_reason = cand.truncation_reason

        if cand_reason.nil?
          @log.call("retake #{i + 1} finished cleanly; kept it")
          return Take.new(result: cand, cost: cost, truncated: false)
        elsif cand.duration > best.duration
          best = cand
          @log.call("retake #{i + 1} still truncated but longer; kept it for now")
        else
          @log.call("retake #{i + 1} not better; discarded")
        end
      end

      @log.call('still truncated after retakes; flagged for review')
      Take.new(result: best, cost: cost, truncated: true)
    end
  end
end
