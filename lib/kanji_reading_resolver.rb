require 'json'

class KanjiReadingResolver
  DATA_PATH = File.expand_path('../../data/kanjidic2_readings.json', __FILE__)

  # Rendaku: voicing of the first kana in a reading for the 2nd+ kanji in a compound.
  RENDAKU_MAP = {
    'か' => ['が'], 'き' => ['ぎ'], 'く' => ['ぐ'], 'け' => ['げ'], 'こ' => ['ご'],
    'さ' => ['ざ'], 'し' => ['じ'], 'す' => ['ず'], 'せ' => ['ぜ'], 'そ' => ['ぞ'],
    'た' => ['だ'], 'ち' => ['ぢ'], 'つ' => ['づ'], 'て' => ['で'], 'と' => ['ど'],
    'は' => ['ば', 'ぱ'], 'ひ' => ['び', 'ぴ'], 'ふ' => ['ぶ', 'ぷ'],
    'へ' => ['べ', 'ぺ'], 'ほ' => ['ぼ', 'ぽ'],
  }.freeze

  def initialize(path = DATA_PATH)
    @readings = JSON.parse(File.read(path))
  end

  # Attempt to split a combined reading across consecutive kanji.
  #
  # @param kanji_chars [Array<String>] individual kanji characters, e.g. ["品", "切"]
  # @param reading [String] combined hiragana reading, e.g. "しなぎ"
  # @return [Array<Array(String, String)>, nil] array of [kanji, reading] pairs, or nil
  def resolve(kanji_chars, reading)
    return nil if kanji_chars.empty? || reading.empty?

    result = []
    if backtrack(kanji_chars, reading, 0, 0, result)
      result
    else
      nil
    end
  end

  private

  def backtrack(kanji_chars, reading, kanji_idx, read_offset, result)
    # Success: all kanji assigned and entire reading consumed
    if kanji_idx == kanji_chars.length
      return read_offset == reading.length
    end

    # Fail: reading exhausted but kanji remain
    return false if read_offset >= reading.length

    kanji = kanji_chars[kanji_idx]
    candidates = candidate_readings(kanji, kanji_idx)

    candidates.each do |candidate|
      if reading[read_offset, candidate.length] == candidate
        result << [kanji, candidate]
        if backtrack(kanji_chars, reading, kanji_idx + 1, read_offset + candidate.length, result)
          return true
        end
        result.pop
      end
    end

    false
  end

  # Get all candidate readings for a kanji, including rendaku variants for non-first position.
  def candidate_readings(kanji, position)
    base_readings = @readings[kanji]
    return [] unless base_readings

    if position == 0
      base_readings
    else
      expanded = base_readings.dup
      base_readings.each do |r|
        next if r.empty?
        first_kana = r[0]
        if RENDAKU_MAP.key?(first_kana)
          RENDAKU_MAP[first_kana].each do |voiced|
            variant = voiced + r[1..]
            expanded << variant unless expanded.include?(variant)
          end
        end
      end
      expanded
    end
  end
end
