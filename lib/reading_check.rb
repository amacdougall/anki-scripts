# frozen_string_literal: true

require 'open3'
require_relative 'mecab_controller'

# Checks generated audio against the card's intended readings, using local
# Whisper (bin/transcribe, whisper.cpp large-v3-turbo; see setup-whisper.sh)
# and MeCab.
#
# Sentences are checked word by word against the Sentence Furigana field: each
# `漢字[かな]` group is a checkpoint, and a group is flagged when the transcript's
# kana, aligned against the expected kana, disagrees inside it. Kana between
# groups (particles, okurigana) only anchors the alignment and is never flagged,
# so particle spellings (は/わ, を/お) can't cause false alarms. The caller can
# then regenerate with just the flagged words spelled in kana.
#
# Whisper can mishear correct audio, so a flag means "worth a retry", not
# "definitely wrong".
module ReadingCheck
  TRANSCRIBE_CMD = File.expand_path('../bin/transcribe', __dir__)

  # Nudges Whisper toward hiragana output, so kana can be compared directly.
  # Any kanji it writes anyway is converted to kana with MeCab.
  HIRAGANA_PROMPT = 'これは ぜんぶ ひらがなで かいた ぶんしょう です。かんじは つかいません。'

  # Above this share of mismatched characters the transcript is treated as
  # unusable (garbled or hallucinated) rather than as evidence of misreadings.
  MAX_ERROR_RATE = 0.5

  # One piece of a furigana string: `text` as written, plus `reading` when the
  # text had a `[reading]` annotation (i.e. it contains kanji).
  Segment = Struct.new(:text, :reading) do
    def kanji? = !reading.nil?
    def spoken = reading || text
  end

  VOWELS = {
    'a' => 'あかさたなはまやらわがざだばぱぁゃ',
    'i' => 'いきしちにひみりぎじぢびぴぃ',
    'u' => 'うくすつぬふむゆるぐずづぶぷぅゅっ',
    'e' => 'えけせてねへめれげぜでべぺぇ',
    'o' => 'おこそとのほもよろをごぞどぼぽぉょ'
  }.flat_map { |vowel, chars| chars.chars.map { |c| [c, vowel] } }.to_h.freeze

  # Vowel characters that lengthen a preceding kana with the given vowel.
  LENGTHENERS = {
    'a' => 'あ', 'i' => 'い', 'u' => 'う', 'e' => 'えい', 'o' => 'おう'
  }.freeze

  module_function

  # True when whisper-cli and its model are installed (bin/transcribe --check)
  # and MeCab works.
  def available?
    system(TRANSCRIBE_CMD, '--check', out: File::NULL, err: File::NULL) && MecabController.available?
  end

  # Parse Anki bracket furigana ("逃[に]げる 竜児[りゅうじ]を") into Segments.
  # The annotated base of a `[reading]` is the text since the last space or `]`,
  # which is how generate-furigana.rb and TextTransforms write it.
  def parse_furigana(furigana)
    furigana.split(/[ 　]+/).flat_map do |token|
      token.scan(/([^\[\]]+)\[([^\]]*)\]|([^\[\]]+)/).map do |base, reading, plain|
        if plain
          Segment.new(plain, nil)
        elsif reading.empty?
          Segment.new(base, nil)
        else
          Segment.new(base, reading)
        end
      end
    end
  end

  # True when every kanji in the furigana has a reading. Unannotated kanji
  # (e.g. 両面宿儺 split as 宿[やど]儺) mean MeCab didn't know the word, so the
  # readings it did give are suspect too, and the kanji can't be spelled in
  # kana for a retry.
  def fully_annotated?(segments)
    segments.none? { |seg| !seg.kanji? && seg.text.match?(/\p{Han}/) }
  end

  # Transcribe a WAV file. Returns the transcript (possibly with kanji).
  def transcribe(wav_path)
    out, status = Open3.capture2(TRANSCRIBE_CMD, wav_path, '-l', 'ja', '--prompt', HIRAGANA_PROMPT,
                                 err: File::NULL)
    raise "transcribe failed (exit #{status.exitstatus})" unless status.success?

    out.strip
  end

  # Kana reading of arbitrary text: kanji go through MeCab, kana pass through.
  def kana_of(text, mecab)
    return text unless text.match?(/\p{Han}/)

    parse_furigana(mecab.generate_furigana(text, ignore_numbers: false)).map(&:spoken).join
  end

  # Phonetic comparison key: hiragana only, no punctuation, and long vowels
  # collapsed (so しょう, しょお and ショー all compare equal).
  def normalize(text)
    normalize_tagged(text.chars.map { |c| [c, nil] }).map(&:first).join
  end

  # normalize over [char, tag] pairs, keeping each surviving character's tag.
  # Collapsing runs across tag boundaries, exactly as it does for untagged text,
  # so expected and heard strings collapse the same way (の+うえ → のえ on both).
  def normalize_tagged(pairs)
    pairs.each_with_object([]) do |(c, tag), out|
      c = c.tr('ァ-ヶ', 'ぁ-ゖ').tr('ぢづ', 'じず')
      next unless c.match?(/[\p{Hiragana}ーa-zA-Z0-9]/)

      prev_vowel = VOWELS[out.last&.first]
      next if c == 'ー' && prev_vowel
      next if prev_vowel && LENGTHENERS[prev_vowel].include?(c)

      out << [c, tag]
    end
  end

  # Check a sentence clip. `segments` come from parse_furigana. Returns a hash:
  #   heard:    the transcript, in kana
  #   flagged:  kanji Segments whose reading the transcript disagrees with
  #   unusable: true if the transcript is too far off to judge
  def check_sentence(wav_path, segments, mecab)
    heard = normalize(kana_of(transcribe(wav_path), mecab))

    # Expected characters, each tagged with the index of its segment.
    expected = normalize_tagged(segments.each_with_index.flat_map { |seg, i| seg.spoken.chars.map { |c| [c, i] } })
    return { heard: heard, flagged: [], unusable: true } if heard.empty? || expected.empty?

    bad, distance = align(expected.map(&:first), heard.chars)
    bad_segments = expected.each_index.select { |k| bad[k] }.map { |k| expected[k][1] }.uniq

    {
      heard: heard,
      flagged: bad_segments.map { |i| segments[i] }.select(&:kanji?),
      unusable: distance > MAX_ERROR_RATE * expected.size
    }
  end

  # Check an isolated word clip against its kana reading. Containment rather
  # than equality, because Whisper sometimes tacks prompt fragments onto very
  # short clips.
  def check_word(wav_path, reading, mecab)
    heard = normalize(kana_of(transcribe(wav_path), mecab))
    { heard: heard, flagged: !heard.include?(normalize(reading)) }
  end

  # Levenshtein alignment of expected vs heard characters. Returns
  # [bad, distance], where bad[k] is true when expected character k was
  # substituted or deleted, or had an insertion next to it inside the same
  # segment run (insertions are charged to the character before them).
  def align(expected, heard)
    n, m = expected.size, heard.size
    d = Array.new(n + 1) { |i| Array.new(m + 1) { |j| i.zero? ? j : (j.zero? ? i : 0) } }
    (1..n).each do |i|
      (1..m).each do |j|
        cost = expected[i - 1] == heard[j - 1] ? 0 : 1
        d[i][j] = [d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1].min
      end
    end

    bad = Array.new(n, false)
    i, j = n, m
    while i > 0 || j > 0
      if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (expected[i - 1] == heard[j - 1] ? 0 : 1)
        bad[i - 1] = true unless expected[i - 1] == heard[j - 1]
        i -= 1
        j -= 1
      elsif i > 0 && d[i][j] == d[i - 1][j] + 1
        bad[i - 1] = true
        i -= 1
      else
        # Insertion: extra heard character. Charge it to the neighbouring
        # expected character only when it falls strictly inside the string,
        # so leading/trailing noise (e.g. hallucinated prompt text) is ignored.
        bad[i - 1] = true if i > 0 && i < n
        j -= 1
      end
    end

    [bad, d[n][m]]
  end
end
