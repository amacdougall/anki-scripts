#!/usr/bin/env ruby

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/yaml_writer'

class ExtractWords
  DEFAULT_OUTPUT = File.join(__dir__, 'temp', 'words.yaml')
  NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME

  def initialize(argv)
    @options = parse_options(argv)
  end

  def run
    AnkiConnect.require_running!

    db = AnkiConnect.new

    begin
      db.connect

      # Find note type
      note_type_id = db.find_note_type_id(NOTE_TYPE_NAME)
      unless note_type_id
        puts "Error: Note type '#{NOTE_TYPE_NAME}' not found"
        exit 1
      end

      if @options[:deck_name]
        # Target a specific deck
        unless db.find_deck_id(@options[:deck_name])
          list_available_decks(db)
          exit 1
        end

        puts "Targeting deck: #{@options[:deck_name]}"
        rows = db.notes_in_deck_with_deck(@options[:deck_name], note_type: NOTE_TYPE_NAME)
      else
        # All decks except the curated source deck
        puts "Targeting all decks except '#{NOTE_TYPE_NAME}'"
        rows = db.notes_in_deck_with_deck(nil, note_type: NOTE_TYPE_NAME, exclude_deck: NOTE_TYPE_NAME)
      end

      notes = build_note_hashes(rows, force: @options[:force])

      if notes.empty?
        puts @options[:force] ? "No notes found." : "No notes need sentences. All caught up!"
        # Still create empty file for consistency
      else
        puts "Found #{notes.length} note(s)#{' (including existing sentences)' if @options[:force]}"
      end

      # Prepare metadata
      deck_label = @options[:deck_name] || "all (except #{NOTE_TYPE_NAME})"
      metadata = {
        'deck_name' => deck_label,
        'note_type_id' => note_type_id,
        'extracted_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'total_notes' => notes.length
      }

      # Write output
      YamlWriter.write_words(@options[:output], metadata, notes)
      puts "Wrote output to: #{@options[:output]}"

    rescue => e
      puts "Error: #{e.message}"
      exit 1
    ensure
      db.close
    end
  end

  private

  def parse_options(argv)
    options = {
      output: DEFAULT_OUTPUT,
      force: false
    }

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: extract-words.rb [options]"
      opts.separator ""
      opts.separator "Extract vocabulary words from Anki deck that need example sentences."
      opts.separator "Output file is always replaced. Use --force to include words that already have sentences."
      opts.separator ""
      opts.separator "Options:"

      opts.on('-d', '--target-deck DECK', "Name of deck to extract from (default: all except '#{NOTE_TYPE_NAME}')") do |deck|
        options[:deck_name] = deck
      end

      opts.on('-o', '--output FILE', "Output YAML file path (default: temp/words.yaml)") do |file|
        options[:output] = file
      end

      opts.on('-f', '--force', 'Extract all words, including ones that already have sentences') do
        options[:force] = true
      end

      opts.on('-h', '--help', 'Show this help message') do
        puts opts
        exit
      end

      opts.on('-?', 'Show this help message') do
        puts opts
        exit
      end
    end

    parser.parse!(argv)
    options
  end

  def build_note_hashes(rows, force: false)
    rows.map do |row|
      fields = row[:fields]

      unless force
        sentence = fields[Kaishi::SENTENCE_IDX] || ''
        next nil unless sentence.strip.empty?
      end

      {
        'note_id' => row[:id],
        'deck_name' => row[:deck],
        'word' => fields[Kaishi::WORD_IDX] || '',
        'word_reading' => fields[Kaishi::WORD_READING_IDX] || '',
        'word_meaning' => fields[Kaishi::WORD_MEANING_IDX] || '',
        'word_furigana' => fields[Kaishi::WORD_FURIGANA_IDX] || '',
        'sentence' => '',
        'sentence_meaning' => '',
        'sentence_furigana' => ''
      }
    end.compact
  end

  def list_available_decks(db)
    puts "Error: Deck not found: #{@options[:deck_name]}"
    puts ""
    puts "Available decks:"

    db.deck_names.sort.each do |name|
      puts "  - #{name}"
    end
  end
end

# Run the script if executed directly
if __FILE__ == $0
  ExtractWords.new(ARGV).run
end
