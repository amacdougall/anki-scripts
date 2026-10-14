# frozen_string_literal: true

require_relative 'kaishi_fields'

# Text and audio helpers shared by the TTS scripts (generate-voicevox-audio.rb,
# generate-gemini-audio.rb).
module TtsText
  # Voice gender preference is carried by these tags. The legacy Notes-field
  # HTML comment (VOICE_COMMENT_RE) is still read as a fallback for notes tagged
  # before the migration.
  VOICE_MALE_TAG = 'voice::male'
  VOICE_FEMALE_TAG = 'voice::female'
  VOICE_COMMENT_RE = /<!--\s*voice:(male|female)\s*-->/

  module_function

  # Strip HTML while preserving the base text of <ruby> tags.
  # Must remove <rt> and <rp> content before stripping remaining tags,
  # otherwise <ruby>凄<rt>すごい</rt></ruby> → "凄すごい" (reads both).
  def strip_html(text)
    text
      .gsub(/<rt[^>]*>.*?<\/rt>/m, '')
      .gsub(/<rp[^>]*>.*?<\/rp>/m, '')
      .gsub(/<[^>]+>/, '')
      .strip
  end

  # Prepare word text for TTS. When the word field contains <ruby> tags (written
  # by the user and therefore trustworthy), replace each ruby block with its <rt>
  # reading so the TTS engine receives the correct pronunciation directly. Falls
  # back to plain strip_html for words without ruby markup.
  def word_tts_text(text)
    return strip_html(text) unless text.include?('<ruby>')

    text
      .gsub(/<ruby[^>]*>.*?<\/ruby>/m) { |m| m.match(/<rt[^>]*>(.*?)<\/rt>/m)&.[](1).to_s }
      .gsub(/<rp[^>]*>.*?<\/rp>/m, '')
      .gsub(/<[^>]+>/, '')
      .strip
  end

  # Apply a short linear fade-in and fade-out to PCM WAV bytes to eliminate
  # clicks/pops from waveforms that don't start or end at zero amplitude.
  # Assumes standard 44-byte header, 16-bit little-endian mono samples.
  def apply_fade(wav_bytes, fade_ms: 10, sample_rate: 24000)
    wav_bytes = wav_bytes.b  # ensure binary encoding before slicing/packing
    header  = wav_bytes[0, 44]
    samples = wav_bytes[44..].unpack('s<*')
    fade_n  = [(sample_rate * fade_ms / 1000.0).round, samples.length / 2].min

    fade_n.times do |i|
      factor = i.to_f / fade_n
      samples[i]          = (samples[i]          * factor).round
      samples[-(i + 1)]   = (samples[-(i + 1)]   * factor).round
    end

    header + samples.pack('s<*')
  end

  # Voice gender preference for a note: 'female', 'male', or nil. The
  # voice::female / voice::male tag is the current signal; a legacy
  # voice:male|female HTML comment in the Notes field is honored as a fallback.
  def voice_gender(note)
    tags = note[:tags] || []
    if tags.include?(VOICE_FEMALE_TAG)
      'female'
    elsif tags.include?(VOICE_MALE_TAG)
      'male'
    else
      note[:fields][Kaishi::NOTES_IDX].to_s[VOICE_COMMENT_RE, 1]
    end
  end
end
