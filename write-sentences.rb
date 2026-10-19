#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes generated example sentences from generate-sentences.rb's YAML file back
# to Anki, the last step of the sentence round trip. Refuses to write if the
# file was extracted from another deck, or if any of its notes aren't in the
# target deck.

require 'set'
require_relative 'lib/script_cli'
require_relative 'lib/sentence_writer'

cli = ScriptCLI.new(
  'write-sentences.rb',
  'Writes generated sentences from a YAML file to the notes in the target deck.'
)
options = cli.options
options[:input] = File.join(__dir__, 'temp', 'example-sentences.yaml')
options[:only_note_ids] = []
cli.on('--input FILE', 'Input YAML file (default: temp/example-sentences.yaml)') { |file| options[:input] = file }
cli.dry_run
cli.on('--only-note-ids IDS', 'Comma-separated note IDs to update') do |ids|
  options[:only_note_ids] = ids.split(',').map(&:to_i)
end
cli.parse!

unless File.exist?(options[:input])
  ProgressReporter.error("Input file not found: #{options[:input]}")
  exit ScriptCLI::EXIT_ERROR
end

deck = options[:target_deck]

begin
  writer = SentenceWriter.new(options[:input], options)

  puts "Loading sentences from: #{options[:input]}"
  data = writer.load_yaml

  unless writer.validate_yaml_structure(data)
    ProgressReporter.error('Invalid YAML structure')
    exit ScriptCLI::EXIT_ERROR
  end

  file_deck = data.dig('metadata', 'target_deck')
  if file_deck && file_deck != deck
    cli.usage_error("#{options[:input]} was extracted from deck '#{file_deck}', not '#{deck}'")
  end

  notes = writer.filter_notes(data['notes'])

  if notes.empty?
    puts 'No valid notes to update.'
    exit ScriptCLI::EXIT_OK
  end

  puts "Found #{notes.size} note(s) to update"
  puts ''

  db = cli.connect!

  begin
    deck_note_ids = cli.notes(db).map { |note| note[:id] }.to_set
    outside = notes.reject { |note| deck_note_ids.include?(note['note_id']) }
    unless outside.empty?
      sample = outside.first(5).map { |note| "#{note['note_id']} (#{note['word']})" }.join(', ')
      ProgressReporter.error("#{outside.size} note(s) in the file aren't in deck '#{deck}', e.g. #{sample}. " \
                             'Nothing was written.')
      exit ScriptCLI::EXIT_ERROR
    end

    if options[:dry_run]
      writer.dry_run_preview(notes, db)
    else
      puts 'Updating notes...'
      puts ''
      writer.write_to_database(notes, db)
      puts ''
      ProgressReporter.success('All updates completed successfully!')
      ProgressReporter.summary(writer.stats)
    end
  ensure
    db.close
  end

  exit(writer.stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)
rescue StandardError => e
  puts ''
  ProgressReporter.error("Fatal error: #{e.message}")
  puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
  exit ScriptCLI::EXIT_ERROR
end
