module GeminiTTS
  DEFAULT_MODEL = 'gemini-3.8-flash-tts'

  # USD per 1M tokens (standard tier), as [input text, output audio]. TTS is text
  # in, audio out, so input tokens price as text and output tokens as audio. The
  # 3.8 prices are launch pricing through 2026-12-31; Google doubles them (to
  # $1.00 / $18.00 and $1.00 / $12.00) on 2027-01-01.
  PRICES_PER_1M = {
    'gemini-3.8-flash-tts' => [0.50, 9.00],
    'gemini-3.8-flash-lite-tts' => [0.50, 6.00],
    'gemini-3.1-flash-tts-preview' => [1.00, 20.00]
  }.freeze

  # Models that read `text` strictly as a verbatim transcript (Gemini 3.8+).
  # Anything prepended to the input is spoken aloud, so delivery direction must
  # ride in each part's `speechMetadata.style` instead. Earlier models take
  # direction as prose prepended to the text.
  TRANSCRIPT_MODEL_RE = /\Agemini-3\.8-/

  def self.transcript_model?(model)
    TRANSCRIPT_MODEL_RE.match?(model.to_s)
  end

  # [input, output] USD per 1M tokens, or nil for an unpriced model.
  def self.price(model)
    PRICES_PER_1M[model.to_s]
  end
end
