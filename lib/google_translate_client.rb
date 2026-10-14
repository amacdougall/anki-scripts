# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'json'

# Client for translating text via Google Translate's free endpoint.
module GoogleTranslateClient
  BASE_URL = 'https://translate.googleapis.com/translate_a/single'
  MAX_RETRIES = 3
  RATE_LIMIT_DELAY = 5
  REQUEST_DELAY = 1

  class Error < StandardError; end
  class RateLimitError < Error; end

  # Translate text from one language to another.
  #
  # @param text [String] the text to translate
  # @param source [String] source language code (default: 'ja')
  # @param target [String] target language code (default: 'en')
  # @param verbose [Boolean] whether to print status messages
  # @return [String] the translated text
  # @raise [RateLimitError] if rate limited after max retries
  # @raise [Error] on unexpected failures
  def self.translate(text, source: 'ja', target: 'en', verbose: false)
    fetch_with_retry(text, source: source, target: target, verbose: verbose)[:translation]
  end

  # Translate text and also return the romanization of the source. Google's
  # endpoint supplies a Hepburn transliteration of the source text alongside the
  # translation, which we can reverse into a kana reading. Single request.
  #
  # @return [Hash] { translation: String, romaji: String|nil }
  def self.translate_with_reading(text, source: 'ja', target: 'en', verbose: false)
    fetch_with_retry(text, source: source, target: target, verbose: verbose)
  end

  private_class_method def self.fetch_with_retry(text, source:, target:, retry_count: 0, verbose: false)
    # dt=t requests the translation; dt=rm requests a romanization of the
    # source text (the same romaji shown in the web UI). Both arrive in one
    # response.
    params = URI.encode_www_form(
      [['client', 'gtx'], ['sl', source], ['tl', target],
       ['dt', 't'], ['dt', 'rm'], ['q', text]]
    )
    uri = URI("#{BASE_URL}?#{params}")

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(uri)
      http.request(request)
    end

    if response.code == '429'
      if retry_count < MAX_RETRIES
        warn "  Rate limited (429), retrying after #{RATE_LIMIT_DELAY} seconds..." if verbose
        sleep RATE_LIMIT_DELAY
        return fetch_with_retry(text, source: source, target: target,
                                retry_count: retry_count + 1, verbose: verbose)
      else
        raise RateLimitError, "Rate limit exceeded after #{MAX_RETRIES} retries"
      end
    end

    sleep REQUEST_DELAY

    unless response.is_a?(Net::HTTPSuccess)
      # Surface the response body — Google's error responses (e.g. 500s) carry a
      # short explanation there that a bare status code hides. Trimmed to keep
      # progress output readable.
      body = response.body.to_s.strip
      detail = body.empty? ? '' : ": #{body[0, 300]}"
      raise Error, "HTTP #{response.code}#{detail}"
    end

    parse_response(response.body)
  rescue RateLimitError, Error
    raise
  rescue StandardError => e
    raise Error, "Translation failed: #{e.message}"
  end

  # The response is a nested array whose first element holds the segments:
  #   [
  #     ["translated text","source text",null,null,10],  # translation segment(s)
  #     [null,null,null,"Romaji"]                         # romanization segment
  #   ]
  # Translation segments carry the text in [0]; the romanization segment has a
  # nil [0] and the source romaji in [3]. Longer text yields multiple
  # translation segments, but a single romanization segment at the end.
  private_class_method def self.parse_response(body)
    data = JSON.parse(body)

    unless data.is_a?(Array) && data[0].is_a?(Array)
      raise Error, "Unexpected response format"
    end

    segments = data[0]
    translation = segments.map { |segment| segment[0] }.compact.join

    romaji_segment = segments.find { |segment| segment[0].nil? && segment[3].is_a?(String) }
    romaji = romaji_segment && romaji_segment[3]

    { translation: translation, romaji: romaji }
  end
end
