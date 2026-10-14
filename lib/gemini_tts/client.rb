require 'base64'

module GeminiTTS
  # Direct client for Gemini TTS via the non-streaming generateContent endpoint,
  # which Google documents as far more truncation-resistant than streaming. One
  # call is one request: no retries (see Resilient for those).
  #
  # Thread safety: share a Client freely for sequential use; give each thread
  # its own for concurrent generation.
  class Client
    attr_reader :default_model

    # Google suggests keeping a single generation under ~800 characters (~45s);
    # longer ones truncate more often. Callers that split text can use this.
    MAX_CHUNK_LENGTH = 800

    def initialize(api_key: ENV['GEMINI_API_KEY'], default_model: DEFAULT_MODEL, connection: nil)
      @api_key = api_key
      @default_model = default_model || DEFAULT_MODEL
      @connection = connection
    end

    # Synthesize `text` with `voice` (a prebuilt name like "Kore"; on 3.8 also a
    # designed "voice_..." ID). `style` is delivery direction; see Request for how
    # each model receives it. Returns a Result, or raises a GeminiTTS::Error.
    def generate(text, voice:, model: nil, style: nil)
      model ||= @default_model
      body = Request.build(text, voice: voice, model: model, style: style)
      response = HTTP.request("Gemini TTS (#{model})") do
        connection.post("models/#{model}:generateContent") do |req|
          req.headers['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end
      end
      build_result(response, model)
    end

    private

    def connection
      @connection ||= HTTP.connection(@api_key)
    end

    def build_result(response, model)
      parsed = HTTP.parse(response)
      candidate = parsed.dig('candidates', 0)
      finish_reason = candidate && candidate['finishReason']
      audio_b64 = audio_data(candidate)

      if audio_b64.nil? || audio_b64.empty?
        # A safety refusal comes back as promptFeedback.blockReason (prompt
        # rejected) or a SAFETY/PROHIBITED_CONTENT finishReason.
        block_reason = parsed.dig('promptFeedback', 'blockReason')
        block_reason ||= finish_reason if %w[SAFETY PROHIBITED_CONTENT].include?(finish_reason)
        if block_reason
          raise ContentBlockedError.new(
            "Gemini TTS blocked the input (#{block_reason}): #{response.body.to_s[0, 500]}",
            response: response, block_reason: block_reason
          )
        end

        raise NoAudioError.new(
          "Gemini TTS returned no audio (finishReason=#{finish_reason || 'none'}): " \
          "#{response.body.to_s[0, 500]}",
          response: response
        )
      end

      Result.new(
        pcm: Base64.decode64(audio_b64),
        finish_reason: finish_reason,
        usage: parsed['usageMetadata'],
        model: model
      )
    end

    def audio_data(candidate)
      parts = candidate&.dig('content', 'parts') || []
      part = parts.find { |p| p.is_a?(Hash) && p.dig('inlineData', 'data') }
      part&.dig('inlineData', 'data')
    end
  end
end
