# frozen_string_literal: true

# Loads the inlined Gemini TTS client (lib/gemini_tts/; faraday comes via
# Bundler, so plain `ruby script.rb` works) and the API key from
# ~/.config/gemini/api_key. An exported GEMINI_API_KEY wins.
require 'bundler/setup'
require_relative 'gemini_tts'

module GeminiSetup
  KEY_PATH = File.expand_path('~/.config/gemini/api_key')

  def self.load_api_key!
    if ENV['GEMINI_API_KEY'].to_s.strip.empty? && File.exist?(KEY_PATH)
      ENV['GEMINI_API_KEY'] = File.read(KEY_PATH).strip
    end
    return unless ENV['GEMINI_API_KEY'].to_s.empty?

    abort "No Gemini API key: export GEMINI_API_KEY, or save the key to #{KEY_PATH}\n" \
          '(mkdir -p ~/.config/gemini; chmod 600 the file). See "Gemini API key" in README.md.'
  end
end

# --help works without a key.
GeminiSetup.load_api_key! unless (ARGV & %w[-h --help -?]).any?
