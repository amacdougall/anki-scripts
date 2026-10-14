# Google Gemini text-to-speech. Inlined copy of the gemini_tts gem; only
# GeminiTTS::Client is used by generate-gemini-audio.rb.
#
#   tts = GeminiTTS::Client.new                      # reads ENV['GEMINI_API_KEY']
#   res = tts.generate('Hello there!', voice: 'Kore', style: 'warm, unhurried')
#   File.binwrite('hello.wav', res.to_wav)
#
#   # Retries, no-audio cache-busting (3.1) and truncation retakes:
#   take = GeminiTTS::Resilient.new(tts).generate('Hello there!', voice: 'Kore')
#   File.binwrite('hello.mp3', take.result.to_mp3)
#
# MP3 output and truncation analysis shell out to sox.
require_relative 'gemini_tts/version'
require_relative 'gemini_tts/errors'
require_relative 'gemini_tts/models'
require_relative 'gemini_tts/audio'
require_relative 'gemini_tts/result'
require_relative 'gemini_tts/request'
require_relative 'gemini_tts/http'
require_relative 'gemini_tts/client'
require_relative 'gemini_tts/resilient'
require_relative 'gemini_tts/voices'
