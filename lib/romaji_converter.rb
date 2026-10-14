# frozen_string_literal: true

# Converts Hepburn romaji (as produced by Google Translate's `dt=rm` output)
# back into hiragana. Used as a last-resort reading source in add-cards.rb when
# neither JMdict nor MeCab supplies a reading.
#
# This is necessarily approximate. Hepburn collapses distinctions that hiragana
# preserves, so a few cases cannot be recovered exactly:
#
#   - Long "o" (macron ō) is rendered おう, which is correct for the great
#     majority of Sino-Japanese readings (かんりょう, とうきょう) but wrong for
#     the minority of native words written おお (おおさか, とおり, こおり).
#   - づ/ぢ are romanized "zu"/"ji" by Hepburn and come back as ず/じ.
#
# These produce a slightly off reading rather than a failure; good enough for a
# fallback, and easily corrected by hand when it matters.
module RomajiConverter
  VOWELS = %w[a i u e o].freeze

  # Macron (and circumflex, a common ASCII-friendly substitute) long vowels,
  # expanded to double vowels before syllable parsing. ō → "ou" by convention.
  MACRONS = {
    'ā' => 'aa', 'ī' => 'ii', 'ū' => 'uu', 'ē' => 'ee', 'ō' => 'ou',
    'â' => 'aa', 'î' => 'ii', 'û' => 'uu', 'ê' => 'ee', 'ô' => 'ou'
  }.freeze

  # Consonants that, when doubled, indicate a sokuon (っ).
  SOKUON_CONSONANTS = %w[k s t c p g z j d b f h r].freeze

  SYLLABLES = {
    # bare vowels
    'a' => 'あ', 'i' => 'い', 'u' => 'う', 'e' => 'え', 'o' => 'お',
    # k / g
    'ka' => 'か', 'ki' => 'き', 'ku' => 'く', 'ke' => 'け', 'ko' => 'こ',
    'kya' => 'きゃ', 'kyu' => 'きゅ', 'kyo' => 'きょ',
    'ga' => 'が', 'gi' => 'ぎ', 'gu' => 'ぐ', 'ge' => 'げ', 'go' => 'ご',
    'gya' => 'ぎゃ', 'gyu' => 'ぎゅ', 'gyo' => 'ぎょ',
    # s / z
    'sa' => 'さ', 'shi' => 'し', 'si' => 'し', 'su' => 'す', 'se' => 'せ', 'so' => 'そ',
    'sha' => 'しゃ', 'shu' => 'しゅ', 'sho' => 'しょ',
    'sya' => 'しゃ', 'syu' => 'しゅ', 'syo' => 'しょ',
    'za' => 'ざ', 'ji' => 'じ', 'zi' => 'じ', 'zu' => 'ず', 'ze' => 'ぜ', 'zo' => 'ぞ',
    'ja' => 'じゃ', 'ju' => 'じゅ', 'jo' => 'じょ',
    'jya' => 'じゃ', 'jyu' => 'じゅ', 'jyo' => 'じょ',
    # t / d
    'ta' => 'た', 'chi' => 'ち', 'tsu' => 'つ', 'te' => 'て', 'to' => 'と',
    'cha' => 'ちゃ', 'chu' => 'ちゅ', 'cho' => 'ちょ',
    'da' => 'だ', 'di' => 'ぢ', 'du' => 'づ', 'de' => 'で', 'do' => 'ど',
    # n
    'na' => 'な', 'ni' => 'に', 'nu' => 'ぬ', 'ne' => 'ね', 'no' => 'の',
    'nya' => 'にゃ', 'nyu' => 'にゅ', 'nyo' => 'にょ',
    # h / b / p / f
    'ha' => 'は', 'hi' => 'ひ', 'fu' => 'ふ', 'hu' => 'ふ', 'he' => 'へ', 'ho' => 'ほ',
    'hya' => 'ひゃ', 'hyu' => 'ひゅ', 'hyo' => 'ひょ',
    'fa' => 'ふぁ', 'fi' => 'ふぃ', 'fe' => 'ふぇ', 'fo' => 'ふぉ',
    'ba' => 'ば', 'bi' => 'び', 'bu' => 'ぶ', 'be' => 'べ', 'bo' => 'ぼ',
    'bya' => 'びゃ', 'byu' => 'びゅ', 'byo' => 'びょ',
    'pa' => 'ぱ', 'pi' => 'ぴ', 'pu' => 'ぷ', 'pe' => 'ぺ', 'po' => 'ぽ',
    'pya' => 'ぴゃ', 'pyu' => 'ぴゅ', 'pyo' => 'ぴょ',
    # m
    'ma' => 'ま', 'mi' => 'み', 'mu' => 'む', 'me' => 'め', 'mo' => 'も',
    'mya' => 'みゃ', 'myu' => 'みゅ', 'myo' => 'みょ',
    # y / r / w
    'ya' => 'や', 'yu' => 'ゆ', 'yo' => 'よ',
    'ra' => 'ら', 'ri' => 'り', 'ru' => 'る', 're' => 'れ', 'ro' => 'ろ',
    'rya' => 'りゃ', 'ryu' => 'りゅ', 'ryo' => 'りょ',
    'wa' => 'わ', 'wo' => 'を'
  }.freeze

  # Convert a Hepburn romaji string to hiragana. Returns nil for nil/blank
  # input. Unrecognized characters are passed through unchanged so problems are
  # visible rather than silently dropped.
  def self.to_hiragana(romaji)
    return nil if romaji.nil?

    s = romaji.strip.downcase
    return nil if s.empty?

    MACRONS.each { |macron, expansion| s = s.gsub(macron, expansion) }

    result = +''
    i = 0
    len = s.length

    while i < len
      c = s[i]
      nxt = s[i + 1]

      # Word/segment boundaries: skip, but a pending sense of 'n' is already
      # resolved by the time we get here.
      if c == ' ' || c == '-' || c == "'"
        i += 1
        next
      end

      # Sokuon: a doubled consonant (kk, ss, tt, pp, ...) becomes っ.
      if SOKUON_CONSONANTS.include?(c) && nxt == c
        result << 'っ'
        i += 1
        next
      end

      # "tch" (e.g. こっち = "kotchi") is a sokuon before ち.
      if c == 't' && nxt == 'c' && s[i + 2] == 'h'
        result << 'っ'
        i += 1
        next
      end

      # Syllabic ん: 'n' not forming a na-row or nya-row syllable.
      if c == 'n' && !(nxt && (VOWELS.include?(nxt) || nxt == 'y'))
        result << 'ん'
        i += 1
        next
      end

      # Longest-match syllable lookup (3, then 2, then 1 characters).
      match = nil
      [3, 2, 1].each do |width|
        seg = s[i, width]
        if seg && SYLLABLES.key?(seg)
          match = seg
          break
        end
      end

      if match
        result << SYLLABLES[match]
        i += match.length
      else
        result << c
        i += 1
      end
    end

    result
  end
end
