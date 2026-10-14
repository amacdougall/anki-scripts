require 'json'

module GeminiTTS
  # Base class for every failure the library raises. Carries the raw Faraday
  # response (when there is one) so callers can inspect status and body.
  class Error < StandardError
    attr_reader :response

    def initialize(message, response: nil)
      super(message)
      @response = response
    end

    def status
      response&.status
    end

    # Google's machine-readable error status from the JSON body, if any (e.g.
    # "RESOURCE_EXHAUSTED", "INVALID_ARGUMENT").
    def code
      return @code if defined?(@code)

      @code = begin
        body = response&.body
        parsed = body ? JSON.parse(body.to_s) : nil
        parsed.is_a?(Hash) ? parsed.dig('error', 'status') : nil
      rescue JSON::ParserError, TypeError
        nil
      end
    end
  end

  # HTTP 402: the account is out of balance. Distinct so callers can abort a
  # whole run rather than burn retries on a hopeless request.
  class InsufficientBalanceError < Error; end

  # HTTP 429: rate limited or quota exhausted. Retryable after a backoff.
  class RateLimitedError < Error; end

  # HTTP 400/404: a malformed request, e.g. a voice that isn't valid for the
  # model. Retrying can't help.
  class BadRequestError < Error; end

  # HTTP 5xx. Transient; retryable.
  class ServerError < Error; end

  # Connection failure or timeout (no HTTP response at all). Retryable.
  class NetworkError < Error; end

  # An HTTP 200 whose candidate carries no audio: the model returned text (or
  # nothing) instead. On 3.1 models this is intermittent and sticky for a given
  # prompt, which is why Resilient perturbs the prompt before retrying.
  class NoAudioError < Error; end

  # The safety filter refused the input (promptFeedback.blockReason, or a
  # SAFETY/PROHIBITED_CONTENT finishReason). Deterministic: retrying or
  # perturbing the text can't help, so it's never retried. The filter weighs
  # the whole prompt, style included, not just the transcript.
  class ContentBlockedError < Error
    attr_reader :block_reason

    def initialize(message, response: nil, block_reason: nil)
      super(message, response: response)
      @block_reason = block_reason
    end

    def code
      @block_reason
    end
  end
end
