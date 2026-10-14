# frozen_string_literal: true

require_relative 'google_translate_client'

# Adapts GoogleTranslateClient to the translate(text) provider interface shared
# with LlmTranslationProvider, so callers can swap providers transparently.
class GoogleTranslationProvider
  def initialize(verbose: false)
    @verbose = verbose
  end

  def translate(text)
    GoogleTranslateClient.translate(text, verbose: @verbose)
  end

  # @return [Hash] { translation: String, romaji: String|nil }
  def translate_with_reading(text)
    GoogleTranslateClient.translate_with_reading(text, verbose: @verbose)
  end
end
