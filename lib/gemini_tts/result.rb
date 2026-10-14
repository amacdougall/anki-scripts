module GeminiTTS
  # One successful generation: the raw PCM plus what the API reported about it.
  class Result
    attr_reader :pcm, :finish_reason, :usage, :model

    # `finish_reason` is the candidate's finishReason: "STOP" on a clean finish,
    # "OTHER"/"MAX_TOKENS" on truncation. `usage` is the raw usageMetadata hash.
    def initialize(pcm:, finish_reason:, usage:, model:)
      @pcm = pcm
      @finish_reason = finish_reason
      @usage = usage
      @model = model
    end

    def duration
      Audio.duration(pcm)
    end

    def to_wav
      Audio.wav(pcm)
    end

    def to_mp3
      @mp3 ||= Audio.mp3(pcm)
    end

    # USD cost from the token counts. Input tokens are text-priced, output
    # (candidate) tokens audio-priced. nil when usage is missing or the model has
    # no known price, so callers treat cost as unknown rather than free.
    def cost
      input_price, output_price = GeminiTTS.price(model)
      return nil unless input_price && usage.is_a?(Hash)

      input = usage['promptTokenCount'] || 0
      output = usage['candidatesTokenCount'] || 0
      (input * input_price + output * output_price) / 1_000_000.0
    end

    # True only when the model EXPLICITLY reported truncation (a non-STOP
    # finishReason). False means "no explicit signal", not "complete".
    def explicitly_truncated?
      !finish_reason.nil? && finish_reason != 'STOP'
    end

    def abrupt_end?
      Audio.abrupt_end_pcm?(pcm)
    end

    # Why this take looks truncated, or nil when it looks complete. The explicit
    # finishReason wins (ground truth, and skips the acoustic work); otherwise the
    # tail of the audio is analyzed, which catches clips the API reports as STOP.
    def truncation_reason
      return "finishReason=#{finish_reason}" if explicitly_truncated?

      abrupt_end? ? 'audio ends abruptly' : nil
    end
  end
end
