# frozen_string_literal: true

require 'yaml'
require_relative 'llm_interface'
require_relative 'response_parser'
require_relative 'text_transforms'
require_relative 'jmdict'
require_relative 'reading_check'

# Second pass over MeCab's sentence furigana: an LLM reads each sentence in
# context and corrects readings MeCab got wrong. MeCab picks one reading per
# word regardless of context (後 あと/のち, 身体 からだ/しんたい, 断った
# ことわった/たった); the model can tell which one the sentence means.
#
# The model returns corrected furigana only for sentences that need changes.
# A correction is accepted only if it keeps the sentence text identical (only
# readings may change) and every reading is kana, so it can't rewrite or
# garble the sentence.
#
# The model's own sense of a word's reading can be wrong (it has accepted
# 大慌て as だいあわて), so each sentence is sent with dictionary notes: the
# JMdict readings of its words, wherever the furigana disagrees with them or
# there are several to choose from.
class FuriganaReviewer
  class ReviewError < StandardError; end

  MAX_RETRIES = 3
  RETRY_DELAY = 2

  # Longest word, in characters, looked up in JMdict.
  MAX_WORD_LENGTH = 8

  # JMdict kana tags for readings that don't count: outdated (ok) and
  # search-only (sk).
  IGNORED_READING_TAGS = %w[ok sk].freeze

  # MeCab parts of speech ([pos1, pos2], UniDic) under which a lone kanji is a
  # word of its own (縁を, 帳が, 何を) rather than part of a verb or compound.
  STANDALONE_KANJI_POS = [%w[名詞 普通名詞], %w[代名詞]].freeze

  # transforms: the deck's TextTransforms entry ({ kanji => 'kanji[reading]' }),
  # passed as fixed readings so the model leaves names and invented words alone.
  # mecab: a MecabController, used to find single-kanji words for the
  # dictionary notes; without one, only words of 2+ characters get notes.
  def initialize(llm:, transforms: nil, mecab: nil)
    @llm = llm
    @mecab = mecab
    @transforms = transforms
  end

  # items: [{ id:, sentence:, furigana: }]. Returns
  #   { corrections: { id => corrected_furigana }, rejected: [[id, reason]] }
  # for the items whose furigana the model changed.
  def review(items)
    data = fetch(build_prompt(items))
    by_id = items.to_h { |item| [item[:id].to_s, item] }
    corrections = {}
    rejected = []

    Array(data['corrections']).each do |entry|
      next unless entry.is_a?(Hash)

      item = by_id[entry['id'].to_s]
      corrected = entry['furigana'].to_s.strip
      next if item.nil? || corrected.empty? || corrected == item[:furigana]

      if (reason = invalid_reason(item, corrected))
        rejected << [item[:id], reason]
      else
        corrections[item[:id]] = corrected
      end
    end

    { corrections: corrections, rejected: rejected }
  end

  # Text with the bracket readings and furigana spacing removed.
  def self.base_text(furigana)
    furigana.gsub(/\[[^\]]*\]/, '').gsub(/[ 　]/, '')
  end

  # Dictionary notes for one sentence's furigana, one line per word worth the
  # model's attention: a word whose furigana reading isn't a JMdict reading,
  # or one with several common JMdict readings to choose from. Words are
  # found left to right, each the longest JMdict kanji form (2+ characters,
  # containing kanji) starting after the previous word, so 台所へ is 台所, not
  # also 所へ. A single kanji is a word only when MeCab (if given) tags it as
  # a standalone noun or pronoun outside those words (縁を, 帳が); anywhere
  # else it's part of a verb or compound (書く, 縁取り).
  #
  # tokens: MecabController#tokens for the sentence's base_text; without them,
  # single kanji get no notes. fixed: the deck's fixed-reading words (names),
  # which get no notes and aren't looked into (竜 in 竜児).
  def self.dictionary_notes(furigana, tokens: nil, fixed: [])
    segments = ReadingCheck.parse_furigana(furigana)
    text = segments.map(&:text).join
    words = [] # [start, length, readings]
    covered_until = 0
    fixed_spans = fixed.flat_map do |word|
      starts = []
      while (found = text.index(word, (starts.last || -1) + 1))
        starts << found
      end
      starts.map { |start| start...start + word.length }
    end

    (0...text.length).each do |start|
      next if start < covered_until

      if (span = fixed_spans.find { |range| range.begin == start })
        covered_until = span.end
        next
      end

      [MAX_WORD_LENGTH, text.length - start].min.downto(2) do |length|
        word = text[start, length]
        next unless word.match?(/\p{Han}/)

        readings = dictionary_readings(word)
        next if readings.empty?

        covered_until = start + length
        words << [start, length, readings]
        break
      end
    end
    words = words.reject { |start, length, _| fixed_spans.any? { |range| range.cover?(start) || range.cover?(start + length - 1) } }
    words += standalone_kanji(text, tokens, fixed_spans, words) if tokens

    words.sort_by(&:first).filter_map do |start, length, readings|
      word = text[start, length]
      current = span_reading(segments, start, length)
      common = readings.select(&:last).map(&:first).uniq
      all = (common + readings.map(&:first)).uniq
      # A lone kanji is offered all its readings: JMdict marks few of them
      # common (not even 縁 えん).
      choices = length == 1 ? all : common
      if current && !all.include?(current)
        "#{word}: furigana reads #{current}, which isn't a dictionary reading. JMdict: #{all.join(', ')}"
      elsif choices.size > 1
        "#{word}: #{length == 1 ? '' : 'common '}JMdict readings #{choices.join(', ')}; pick the one this sentence means"
      end
    end
  end

  # Single kanji MeCab tags as standalone words, outside the fixed words and
  # the +words+ already found, as [start, length, readings]. Empty if MeCab's
  # tokens don't line up with the text.
  def self.standalone_kanji(text, tokens, fixed_spans, words)
    covered = words.flat_map { |start, length, _| (start...start + length).to_a } +
              fixed_spans.flat_map(&:to_a)
    found = []
    offset = 0
    tokens.each do |surface, pos1, pos2|
      return [] unless text[offset, surface.length] == surface

      if surface.match?(/\A\p{Han}\z/) && !covered.include?(offset) &&
         STANDALONE_KANJI_POS.any? { |pos| pos == [pos1, pos2].first(pos.size) }
        readings = dictionary_readings(surface, nouns_only: true)
        found << [offset, 1, readings] unless readings.empty?
      end
      offset += surface.length
    end
    found
  end

  # JMdict readings of +word+ as a kanji form, as [hiragana, common?] pairs.
  # Commonness is per entry, not per spelling (からだ is common thanks to 体,
  # and 身体 shares its entry), so it's only a rough filter. nouns_only skips
  # entries that aren't nouns or pronouns, for a kanji MeCab tagged as one
  # (家 as いえ/うち, not the suffixes け, か).
  def self.dictionary_readings(word, nouns_only: false)
    JMDict.entries_for(word).flat_map do |entry|
      next [] unless JMDict.kanji_forms(entry).include?(word)
      next [] if nouns_only && JMDict.parts_of_speech(entry).intersection(%w[n pn]).empty?

      (entry['kana'] || []).select do |kana|
        applies = kana['appliesToKanji'] || ['*']
        (applies.include?('*') || applies.include?(word)) && (kana['tags'] || []).intersection(IGNORED_READING_TAGS).empty?
      end.map { |kana| [hiragana(kana['text']), kana['common'] == true] }
    end.uniq
  end

  # What the furigana says for text[start, length], or nil when that can't be
  # told: a bracket group straddles the span's edge, or a kanji in it has no
  # reading.
  def self.span_reading(segments, start, length)
    reading = +''
    seg_start = 0
    segments.each_with_index do |seg, i|
      seg_end = seg_start + seg.text.length
      if seg_end > start && seg_start < start + length
        if seg.kanji?
          return nil if seg_start < start || seg_end > start + length

          reading << seg.reading
        else
          part = seg.text[[start - seg_start, 0].max...[start + length - seg_start, seg.text.length].min]
          return nil if part.match?(/\p{Han}/)

          reading << part
        end
      end
      seg_start = seg_end
    end
    hiragana(reading)
  end

  def self.hiragana(text)
    text.tr('ァ-ヶ', 'ぁ-ゖ')
  end
  private_class_method :standalone_kanji, :dictionary_readings, :span_reading, :hiragana

  private

  def invalid_reason(item, corrected)
    unless self.class.base_text(corrected) == self.class.base_text(item[:furigana])
      return 'changed the sentence text, not just readings'
    end

    bad = corrected.scan(/\[([^\]]*)\]/).flatten.find { |r| !r.match?(/\A[\p{Hiragana}\p{Katakana}ー]+\z/) }
    return "non-kana reading [#{bad}]" if bad

    nil
  end

  def fetch(prompt)
    attempt = 0
    begin
      attempt += 1
      data = YAML.safe_load(ResponseParser.extract_yaml(@llm.generate(prompt)))
      data = { 'corrections' => [] } if data.nil?
      raise ReviewError, "Expected a YAML hash, got #{data.class}" unless data.is_a?(Hash)

      data
    rescue LLMInterface::APIError, Psych::SyntaxError, ReviewError => e
      raise ReviewError, "Failed after #{MAX_RETRIES} attempts: #{e.message}" if attempt >= MAX_RETRIES

      sleep(RETRY_DELAY * attempt)
      retry
    end
  end

  def build_prompt(items)
    all_tokens = @mecab&.tokens(items.map { |item| self.class.base_text(item[:furigana]) })
    fixed = (@transforms || {}).keys
    listing = items.each_with_index.map do |item, i|
      entry = "- id: #{item[:id]}\n  furigana: #{item[:furigana].to_json}"
      notes = self.class.dictionary_notes(item[:furigana], tokens: all_tokens&.[](i), fixed: fixed)
      entry += "\n  dictionary:\n#{notes.map { |note| "    - #{note.to_json}" }.join("\n")}" unless notes.empty?
      entry
    end.join("\n")

    <<~PROMPT
      You are checking furigana (kanji readings) on Japanese example sentences.
      Each sentence below is in Anki bracket notation: a reading in [brackets]
      follows the kanji it belongs to, e.g. 戦[たたか]いの 後[あと]. The readings
      were produced by a dictionary-based parser, which ignores context and
      sometimes picks the wrong reading: 後 as のち where the sentence means あと,
      身体 as しんたい where it means からだ, 断った as たった where it means
      ことわった, 一人 read piecewise as いちにん.

      For each sentence, decide whether every reading is the one a native
      speaker would use in this sentence. Correct only readings that are wrong.

      Some sentences come with dictionary notes, looked up in JMdict for the
      words in that sentence. Trust them over your own memory of a word:
      - If the furigana's reading isn't a dictionary reading, use the
        dictionary's (e.g. 大[だい]慌[あわ]て → 大[おお]慌[あわ]て), unless the
        word is a name or deliberate slang, or isn't really that word here.
        The lookup matches text, not grammar, so it can catch part of a
        longer or inflected word (微笑 in 微笑んで is 微笑む, read ほほえ) or
        straddle two words.
      - If there are several dictionary readings, choose the one that fits the
        sentence; the furigana may already have it.
      #{reading_hints}
      Rules for a corrected sentence:
      - Keep every character of the sentence exactly as it is; change only what
        is inside [brackets], or where a bracket group starts and ends.
      - Readings must be hiragana (or katakana where the original uses it).
      - Keep the existing spacing and style; e.g. change 後[のち] to 後[あと].
      - Don't add readings to kana, and don't change readings that are merely
        split differently from how you'd split them.

      Sentences:
      #{listing}

      IMPORTANT: End your response with a line containing only three dashes
      (---) followed by valid YAML with a single "corrections" key: a list of
      only the sentences you changed, each with its id and the full corrected
      furigana string. If every sentence is correct, use an empty list.

      Example response format:
      ---
      corrections:
        - id: 3
          furigana: "戦[たたか]いの 後[あと]、みんなで 宿[やど]に 泊[と]まった。"
    PROMPT
  end

  def reading_hints
    return '' if @transforms.nil? || @transforms.empty?

    lines = @transforms.map { |kanji, bracket| "  #{kanji} is read #{TextTransforms.extract_reading(bracket)}" }
    <<~HINTS

      These readings are fixed for this deck (names and special terms); never
      change them:
      #{lines.join("\n")}
    HINTS
  end
end
