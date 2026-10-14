#!/usr/bin/env ruby

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/pitch_database'
require_relative 'lib/pitch_accent_renderer'
require_relative 'lib/progress_reporter'

# Field index for pitch accent (Kaishi 1.5k format)
PITCH_ACCENT_IDX = 10

# Tag marking a note whose pitch-accent field was auto-generated.
PITCH_ACCENT_TAG = 'generated::pitch-accent'

# Note type to target across all decks
NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME

# Parse command-line arguments
options = {
  dry_run: false,
  limit: nil,
  force: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: generate-pitch-accent.rb [options]"
  opts.separator ""
  opts.separator "Generates pitch accent HTML notation for Anki flashcards."
  opts.separator "Operates on all notes using the '#{NOTE_TYPE_NAME}' note type."
  opts.separator ""
  opts.separator "Options:"

  opts.on("--dry-run", "Preview changes without modifying database") do
    options[:dry_run] = true
  end

  opts.on("--limit N", Integer, "Process only first N notes") do |n|
    options[:limit] = n
  end

  opts.on("--force", "Overwrite existing pitch accent data") do
    options[:force] = true
  end

  opts.on("-h", "--help", "-?", "Show this message") do
    puts opts
    exit
  end
end.parse!

# Anki must be running with the AnkiConnect add-on installed.
AnkiConnect.require_running!
ProgressReporter.success("Connected to Anki via AnkiConnect")
puts ""

# Load pitch database
begin
  puts "Loading pitch database..."
  pitch_db = PitchDatabase.new
  pitch_db.load
  ProgressReporter.success("Loaded #{pitch_db.entry_count} pitch accent entries")
  puts ""
rescue => e
  ProgressReporter.error("Failed to load pitch database: #{e.message}")
  exit 1
end

db = AnkiConnect.new.connect

begin
  # Find note type ID
  puts "Finding note type: #{NOTE_TYPE_NAME}"
  note_type_id = db.find_note_type_id(NOTE_TYPE_NAME)

  unless note_type_id
    ProgressReporter.error("Note type not found: #{NOTE_TYPE_NAME}")
    exit 1
  end

  # The deck of the same name is already curated; exclude it
  all_notes = db.notes_in_deck(nil, note_type: NOTE_TYPE_NAME, exclude_deck: NOTE_TYPE_NAME)

  ProgressReporter.success("Found #{all_notes.size} notes with note type '#{NOTE_TYPE_NAME}'")
  puts ""

  # Filter notes that need processing
  notes_to_process = all_notes.select do |note|
    pitch_field = note[:fields][PITCH_ACCENT_IDX] || ''

    # Skip if already generated (unless --force). The generated::pitch-accent
    # tag is the current signal; the legacy HTML-comment marker is recognized as
    # a fallback so pre-migration notes aren't regenerated.
    already_generated = note[:tags]&.include?(PITCH_ACCENT_TAG) ||
                        pitch_field.include?(PitchAccentRenderer::GENERATED_MARKER)
    if !options[:force] && already_generated
      false
    else
      true
    end
  end

  # Apply limit if specified
  if options[:limit]
    notes_to_process = notes_to_process.take(options[:limit])
  end

  puts "Notes to process: #{notes_to_process.size}"
  puts ""

  if notes_to_process.empty?
    puts "No notes to process!"
    puts ""
    if !options[:force]
      puts "Note: Use --force to regenerate existing pitch accent data"
    end
    exit 0
  end

  # Statistics
  stats = {
    total: notes_to_process.size,
    success: 0,
    not_found: 0,
    ambiguous: 0,
    updated: 0,
    errors: 0
  }

  # Process notes
  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  db.transaction do
    notes_to_process.each_with_index do |note, idx|
      note_id = note[:id]
      fields = note[:fields]

      # Extract word and reading
      word = fields[Kaishi::WORD_IDX] || ''
      reading = fields[Kaishi::WORD_READING_IDX] || ''

      # Check for multiple readings first
      all_entries = pitch_db.lookup_all(word)

      # If multiple readings exist and no reading provided, mark as ambiguous
      if all_entries.length > 1 && reading.empty?
        readings_list = all_entries.map { |e| "#{e[:reading]} (#{e[:pattern]})" }.join(', ')
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} ⚠ Multiple readings: #{readings_list}")
        stats[:ambiguous] += 1
        next
      end

      # Look up pitch data
      pitch_data = pitch_db.lookup(word, reading.empty? ? nil : reading)

      if pitch_data.nil?
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} (#{reading}) ✗ Not found in database")
        stats[:not_found] += 1
        next
      end

      # Generate HTML
      html = PitchAccentRenderer.to_kaishi_html(pitch_data[:reading], pitch_data[:pitch])

      if html.nil?
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} (#{reading}) ✗ Failed to generate HTML")
        stats[:errors] += 1
        next
      end

      # Update note field
      fields[PITCH_ACCENT_IDX] = html

      if options[:dry_run]
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} (#{reading}) ✓ Pattern #{pitch_data[:pattern]} [DRY RUN]")
        stats[:success] += 1
      else
        if db.update_note(note_id, fields)
          db.add_tags(note_id, PITCH_ACCENT_TAG)
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} (#{reading}) ✓ Pattern #{pitch_data[:pattern]}")
          stats[:success] += 1
          stats[:updated] += 1
        else
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} (#{reading}) ✗ Update failed")
          stats[:errors] += 1
        end
      end
    end
  end

  # Display summary
  puts ""
  puts "=" * 70
  puts "SUMMARY"
  puts "=" * 70
  puts "  Total notes:          #{stats[:total]}"
  puts "  Success:              #{stats[:success]}"
  puts "  Updated:              #{stats[:updated]}" unless options[:dry_run]
  puts ""
  puts "  Issues:"
  puts "    Not found:          #{stats[:not_found]}"
  puts "    Ambiguous reading:  #{stats[:ambiguous]}"
  puts "    Errors:             #{stats[:errors]}"
  puts "=" * 70
  puts ""

  if options[:dry_run]
    puts "This was a dry run. No changes were made to the database."
    puts "Run without --dry-run to apply changes."
  elsif stats[:updated] > 0
    ProgressReporter.success("Successfully updated #{stats[:updated]} notes!")
  end

  # Exit with appropriate code
  exit(stats[:errors] > 0 ? 1 : 0)

ensure
  db.close
end
