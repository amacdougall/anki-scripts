#!/usr/bin/env ruby

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/sentence_writer'
require_relative 'lib/progress_reporter'

# Parse command-line arguments
options = {
  input: File.join(__dir__, 'temp', 'example-sentences.yaml'),
  dry_run: false,
  only_note_ids: []
}

OptionParser.new do |opts|
  opts.banner = "Usage: write-sentences.rb [options]"
  opts.separator ""
  opts.separator "Writes generated sentences from YAML file to Anki database."
  opts.separator ""
  opts.separator "Options:"

  opts.on("--input FILE", "Input YAML file (default: temp/example-sentences.yaml)") do |file|
    options[:input] = file
  end

  opts.on("--dry-run", "Preview changes without modifying database") do
    options[:dry_run] = true
  end

  opts.on("--only-note-ids IDS", "Comma-separated note IDs to update") do |ids|
    options[:only_note_ids] = ids.split(',').map(&:to_i)
  end

  opts.on("-h", "--help", "-?", "Show this message") do
    puts opts
    exit
  end
end.parse!

# Validate input file exists
unless File.exist?(options[:input])
  puts "Error: Input file not found: #{options[:input]}"
  exit 1
end

# Anki must be running with the AnkiConnect add-on installed.
AnkiConnect.require_running!

# Load and process data
begin
  writer = SentenceWriter.new(options[:input], options)

  # Load YAML
  puts "Loading sentences from: #{options[:input]}"
  data = writer.load_yaml

  # Validate structure
  unless writer.validate_yaml_structure(data)
    puts "Error: Invalid YAML structure"
    exit 1
  end

  # Filter and validate notes
  notes = writer.filter_notes(data['notes'])

  if notes.empty?
    puts "No valid notes to update."
    exit 0
  end

  puts "Found #{notes.size} note(s) to update"
  puts ""

  # Connect to Anki
  db = AnkiConnect.new.connect

  begin
    if options[:dry_run]
      writer.dry_run_preview(notes, db)
    else
      puts "Updating notes..."
      puts ""
      writer.write_to_database(notes, db)
      puts ""
      ProgressReporter.success("All updates completed successfully!")
    end

    # Display summary
    ProgressReporter.summary(writer.stats) unless options[:dry_run]

  ensure
    db.close
  end

  # Exit with appropriate code
  if writer.stats[:errors] > 0
    exit 1
  else
    exit 0
  end

rescue => e
  puts ""
  ProgressReporter.error("Fatal error: #{e.message}")
  puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
  exit 1
end
