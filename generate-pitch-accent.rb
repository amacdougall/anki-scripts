#!/usr/bin/env ruby

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/pitch_database'
require_relative 'lib/pitch_accent_renderer'

PITCH_ACCENT_IDX = Kaishi::PITCH_ACCENT_IDX
PITCH_ACCENT_TAG = DeckStatus::PITCH_ACCENT_TAG

# Words Wadoku has no entry for, or several with no reading to choose between,
# get this tag so they stop counting as missing: a few gaps are fine, since the
# audio carries the pitch too. --force tries them again.
UNAVAILABLE_TAG = DeckStatus::PITCH_ACCENT_UNAVAILABLE_TAG

cli = ScriptCLI.new(
  'generate-pitch-accent.rb',
  "Generates pitch accent diagrams from Wadoku's data. Words Wadoku doesn't know",
  "(or can't disambiguate without a reading) are tagged #{UNAVAILABLE_TAG} and skipped from then on."
)
cli.dry_run
cli.limit
cli.force('Regenerate existing pitch accent, and retry words tagged unavailable')
options = cli.parse!

db = cli.connect!

# Load pitch database
begin
  puts "Loading pitch database..."
  pitch_db = PitchDatabase.new
  pitch_db.load
  ProgressReporter.success("Loaded #{pitch_db.entry_count} pitch accent entries")
  puts ""
rescue => e
  ProgressReporter.error("Failed to load pitch database: #{e.message}")
  exit ScriptCLI::EXIT_ERROR
end

begin
  all_notes = cli.notes(db)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")
  puts ""

  notes_to_process = all_notes.select do |note|
    options[:force] || DeckStatus.needs_pitch_accent?(note)
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
    exit ScriptCLI::EXIT_OK
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
        db.add_tags(note_id, UNAVAILABLE_TAG) unless options[:dry_run]
        next
      end

      # Look up pitch data
      pitch_data = pitch_db.lookup(word, reading.empty? ? nil : reading)

      if pitch_data.nil?
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} (#{reading}) ✗ Not found in database")
        stats[:not_found] += 1
        db.add_tags(note_id, UNAVAILABLE_TAG) unless options[:dry_run]
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
          db.remove_tags(note_id, UNAVAILABLE_TAG) if (note[:tags] || []).include?(UNAVAILABLE_TAG)
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
  puts "    (both tagged #{UNAVAILABLE_TAG})" unless options[:dry_run] || stats[:not_found] + stats[:ambiguous] == 0
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
  exit(stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
