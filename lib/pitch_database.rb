require 'csv'

class PitchDatabase
  FIELD_SEPARATOR = "\u241e"  # ␞ separates fields
  ORTHO_SEPARATOR = "\u241f"  # ␟ separates orthographies

  attr_reader :entries, :entry_count

  DEFAULT_PATH = File.expand_path('../data/wadoku_pitchdb.csv', __dir__)

  def initialize(path = DEFAULT_PATH)
    @path = path
    @entries = {}  # key: "word:reading", value: entry hash
    @word_index = {}  # key: word, value: array of entries (all readings)
    @entry_count = 0
  end

  # Load the pitch database into memory
  def load
    raise "Pitch database not found: #{@path} (run ./bootstrap.rb)" unless File.exist?(@path)

    File.foreach(@path, encoding: 'UTF-8') do |line|
      line.strip!
      next if line.empty?

      fields = line.split(FIELD_SEPARATOR)
      next if fields.length < 5

      orthos_raw = fields[0]
      reading = fields[1]
      accent_notation = fields[2]
      pattern = fields[3]
      pitch = fields[4]

      # Extract orthographies (multiple variants separated by ␟)
      orthographies = orthos_raw.split(ORTHO_SEPARATOR).map(&:strip)

      # Clean reading (remove special markers)
      clean_reading = clean_reading_string(reading)

      entry = {
        orthographies: orthographies,
        reading: clean_reading,
        accent_notation: accent_notation,
        pattern: pattern,
        pitch: pitch
      }

      # Index by each orthography + reading
      orthographies.each do |ortho|
        key = lookup_key(ortho, clean_reading)
        @entries[key] = entry

        # Also index by word only
        @word_index[ortho] ||= []
        @word_index[ortho] << entry unless @word_index[ortho].include?(entry)
      end

      @entry_count += 1
    end

    self
  end

  # Look up word by orthography and reading
  # Returns: { reading:, pattern:, pitch: } or nil
  def lookup(word, reading = nil)
    if reading
      clean_read = clean_reading_string(reading)
      key = lookup_key(word, clean_read)
      entry = @entries[key]
      return format_entry(entry) if entry
      # Reading was provided but didn't match — don't guess
      return nil
    end

    # No reading provided: use word-only lookup
    entries = @word_index[word]
    return nil if entries.nil? || entries.empty?

    # Return first entry
    format_entry(entries.first)
  end

  # Returns all entries for a word (all readings)
  def lookup_all(word)
    entries = @word_index[word]
    return [] if entries.nil?

    entries.map { |e| format_entry(e) }
  end

  private

  def lookup_key(word, reading)
    "#{word}:#{reading}"
  end

  def clean_reading_string(reading)
    # Remove special markers commonly found in the database
    # Keep only hiragana, katakana, and long vowel mark
    reading.gsub(/[^ぁ-んァ-ンー]/, '')
  end

  def format_entry(entry)
    return nil if entry.nil?

    {
      reading: entry[:reading],
      pattern: entry[:pattern],
      pitch: entry[:pitch]
    }
  end
end
