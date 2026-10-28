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

  # English inside a Japanese sentence: words joined by whitespace (optionally
  # after ASCII punctuation, as in "Relax. It's"), plus any trailing punctuation.
  # A token may be a number ("just 20 minutes"); see spoken_english? for which
  # runs count as English.
  ENGLISH_TOKEN = %r{[A-Za-z0-9]+(?:['’/-][A-Za-z0-9]+)*}
  ENGLISH_RUN_RE = /(?<![A-Za-z0-9'’])#{ENGLISH_TOKEN}(?:[,.!?;:"]*[ \t]+["(]?#{ENGLISH_TOKEN})*[,.!?;:]*/

  # Grammar words: pronouns, auxiliaries, prepositions, conjunctions and the
  # like. Someone speaking English uses them; names, titles and loanword
  # phrases (Black Box, Prince Paul, weekly sync) almost never do.
  ENGLISH_GRAMMAR_WORDS = %w[
    i me my mine you your yours he him his she her it its we us our they them their
    this that these those what who where when why how
    am is are was were be been being do does did have has had
    will would can could should shall may might must
    to of in on at for with from by about into as
    and but or so if because than not just very gonna wanna there here
    the a an
    i'm it's that's he's she's what's there's let's you're we're they're
    i've you've we've they've i'll you'll he'll she'll it'll we'll they'll i'd you'd
  ].to_set.freeze
  LEADING_ARTICLES = %w[the a an].freeze

  module_function

  # True when a run of English reads as speech rather than a name or title: two
  # or more words, at least one a grammar word. A leading article doesn't count,
  # so "The Baby-Sitters Club" stays a title while "The sky is blue" is speech.
  def spoken_english?(run)
    words = run.scan(ENGLISH_TOKEN).select { |token| token.match?(/[A-Za-z]/) }.map { |w| w.downcase.tr('’', "'") }
    return false if words.size < 2

    words = words.drop(1) if LEADING_ARTICLES.include?(words.first)
    words.any? { |w| ENGLISH_GRAMMAR_WORDS.include?(w) || w.end_with?("n't") }
  end

  # Split TTS text into [language, text] pairs, :en for each run of spoken
  # English (see spoken_english?) and :ja for everything else, in order. Lone
  # English words (OK, Tシャツ's T) and names stay in Japanese, where the voice
  # reads them as loanwords. Pieces with nothing to speak (a bare 「 or 、) are
  # dropped.
  def language_segments(text)
    segments = []
    pos = 0
    text.to_enum(:scan, ENGLISH_RUN_RE).each do
      match = Regexp.last_match
      next unless spoken_english?(match[0])

      segments << [:ja, text[pos...match.begin(0)]]
      segments << [:en, match[0]]
      pos = match.end(0)
    end
    segments << [:ja, text[pos..]]
    segments.map { |lang, piece| [lang, piece.strip] }.select { |_, piece| piece.match?(/[\p{L}\p{N}]/) }
  end

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
