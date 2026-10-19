#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the words in a deck that have no example sentence yet to a YAML file,
# the first step of the sentence round trip:
#
#   extract-words.rb → generate-sentences.rb → write-sentences.rb
#
# The file records the target deck, which write-sentences.rb checks before
# writing anything back.

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/yaml_writer'

DEFAULT_OUTPUT = File.join(__dir__, 'temp', 'words.yaml')

cli = ScriptCLI.new(
  'extract-words.rb',
  'Extracts the words in a deck that need example sentences into a YAML file for',
  'generate-sentences.rb. The output file is always replaced.'
)
options = cli.options
options[:output] = DEFAULT_OUTPUT
cli.on('-o', '--output FILE', 'Output YAML file (default: temp/words.yaml)') { |file| options[:output] = file }
cli.force('Extract every word, including ones that already have sentences')
cli.parse!

db = cli.connect!

begin
  rows = cli.notes(db, with_deck: true)
  rows = rows.select { |row| DeckStatus.needs_sentence?(row) } unless options[:force]

  notes = rows.map do |row|
    fields = row[:fields]
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
  end

  if notes.empty?
    # Still write the (empty) file, so the next step doesn't pick up a stale one.
    puts options[:force] ? 'No notes found.' : 'No notes need sentences. All caught up!'
  else
    puts "Found #{notes.length} note(s)#{' (including existing sentences)' if options[:force]}"
  end

  metadata = {
    'target_deck' => options[:target_deck],
    'note_type' => Kaishi::NOTE_TYPE_NAME,
    'extracted_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
    'total_notes' => notes.length
  }
  YamlWriter.write_words(options[:output], metadata, notes)
  puts "Wrote output to: #{options[:output]}"
rescue AnkiConnect::Error => e
  ProgressReporter.error(e.message)
  exit ScriptCLI::EXIT_ERROR
ensure
  db.close
end
