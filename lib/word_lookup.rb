# frozen_string_literal: true

# Resolve a Japanese word's reading and English meaning from dictionary
# sources: a local JMdict lookup first, with a Google Translate fallback. This
# is the shared lookup used both when creating new cards (add-cards.rb) and when
# backfilling meanings on existing cards (add-meanings.rb).

require_relative 'jmdict'
require_relative 'google_translation_provider'
require_relative 'romaji_converter'
require_relative 'progress_reporter'

module WordLookup
  # Resolve a word's reading and meaning.
  #
  # Tries JMdict first; if it yields no meaning, falls back to a translation
  # provider (Google Translate by default; see TranslatorFactory for LLM
  # alternatives) and derives a kana reading from its romanization when JMdict
  # gave none. A provided known_reading is preferred when choosing among
  # JMdict entries and is never overwritten.
  #
  # Returns { reading:, meaning:, usually_kana: } where reading and meaning are
  # strings (possibly empty). Propagates errors from the fallback provider on
  # failure (e.g. GoogleTranslateClient::RateLimitError for the default
  # backend) — callers should decide whether to stop. (Local JMdict has no
  # rate limit.)
  def self.resolve(word, known_reading: nil, verbose: true, provider: nil)
    provider ||= GoogleTranslationProvider.new(verbose: verbose)

    result = lookup(word, known_reading: known_reading, verbose: verbose)

    reading = blank?(known_reading) ? result[:reading] : known_reading
    meaning = result[:meaning]
    usually_kana = result[:usually_kana]

    if blank?(meaning)
      puts "  No JMdict meaning; falling back to #{provider.class}" if verbose
      translation = provider.translate_with_reading(word)
      meaning = translation[:translation] unless blank?(translation[:translation])

      # JMdict supplied no reading; derive one from Google's romanization so the
      # card isn't left reading-less. Approximate (see RomajiConverter), but
      # better than nothing for words our dictionaries don't cover.
      if blank?(reading)
        kana = RomajiConverter.to_hiragana(translation[:romaji])
        unless blank?(kana)
          reading = kana
          puts "  Derived reading from romaji: #{translation[:romaji]} → #{kana}" if verbose
        end
      end
    end

    # Normalize: an all-kana word is its own reading; everything else falls back
    # to empty strings rather than nil.
    reading = all_kana?(word) ? word : '' if blank?(reading)
    meaning = '' if meaning.nil?

    { reading: reading, meaning: meaning, usually_kana: usually_kana }
  end

  # Look up a word in JMdict. Only considers entries whose forms include the
  # queried word exactly. When a known_reading is provided, prefers entries with
  # that reading; falls back to the first matching entry.
  # Returns { reading:, meaning:, usually_kana: }.
  def self.lookup(word, known_reading: nil, verbose: true)
    matching = JMDict.entries_for(word)

    reading = nil
    meaning = nil
    usually_kana = false

    if !matching.empty?
      chosen = if known_reading
        matching.find { |e| entry_has_reading?(e, known_reading) } || matching.first
      else
        matching.first
      end
      reading = extract_reading(chosen)
      meaning = extract_definitions(chosen)
      usually_kana = usually_kana?(chosen)
    else
      ProgressReporter.warning("No JMdict entry found for: #{word}")
    end

    { reading: reading, meaning: meaning, usually_kana: usually_kana }
  end

  # Extract definitions from a JMdict entry, one line per sense. When an entry
  # has multiple senses, formats them as a numbered list.
  def self.extract_definitions(entry)
    return '' unless entry

    lines = JMDict.senses(entry).map do |sense|
      JMDict.sense_glosses(sense).join(', ')
    end.reject(&:empty?)

    if lines.length > 1
      lines.each_with_index.map { |line, i| "#{i + 1}. #{line}" }.join("<br>\n")
    else
      lines.first || ''
    end
  end

  # Extract the primary reading from a JMdict entry.
  def self.extract_reading(entry)
    JMDict.readings(entry).first
  end

  # Whether a JMdict entry is tagged "uk" (usually written using kana alone).
  def self.usually_kana?(entry)
    return false unless entry

    JMDict.misc_tags(entry).include?('uk')
  end

  # Check whether a JMdict entry includes the given reading.
  def self.entry_has_reading?(entry, reading)
    JMDict.readings(entry).include?(reading)
  end

  def self.all_kana?(text)
    text.match?(/\A[\p{Hiragana}\p{Katakana}ー]+\z/)
  end

  def self.blank?(str)
    str.nil? || str.strip.empty?
  end
  private_class_method :blank?
end
