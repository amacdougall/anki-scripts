require 'faraday'
require 'json'

module GeminiTTS
  # The Faraday plumbing shared by Client and Voices: the connection, and mapping
  # transport failures and non-2xx statuses onto the library's error classes.
  module HTTP
    BASE_URL = 'https://generativelanguage.googleapis.com/v1beta/'

    # Generations run up to about a minute; this only guards against a hung
    # socket stalling a worker forever.
    TIMEOUT = 300

    module_function

    def connection(api_key)
      raise Error, 'No Gemini API key: pass api_key: or set GEMINI_API_KEY' if api_key.to_s.empty?

      Faraday.new(url: BASE_URL, headers: { 'x-goog-api-key' => api_key }) do |f|
        f.options.timeout = TIMEOUT
      end
    end

    # Runs the request block, returning the response on 2xx and raising the
    # matching error otherwise. `what` names the operation in messages.
    def request(what)
      response =
        begin
          yield
        rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
          raise NetworkError, "#{what}: #{e.class}: #{e.message}"
        end
      return response if response.status.between?(200, 299)

      message = "#{what} failed with HTTP #{response.status}: #{response.body.to_s[0, 500]}"
      klass =
        case response.status
        when 402 then InsufficientBalanceError
        when 429 then RateLimitedError
        when 400, 404 then BadRequestError
        when 500..599 then ServerError
        else Error
        end
      raise klass.new(message, response: response)
    end

    def parse(response)
      body = response.body.to_s
      body.empty? ? {} : JSON.parse(body)
    end
  end
end
