#!/usr/bin/env ruby

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'

cli = ScriptCLI.new(
  'strip-word-html.rb',
  'Strips stray HTML from the Word, Word Furigana, Sentence and Sentence Furigana',
  'fields. Reader tools tend to leave it behind. <ruby> furigana and <br> line',
  'breaks are kept.'
)
cli.dry_run
cli.limit('Process only the first N notes with HTML')
options = cli.parse!

db = cli.connect!

begin
  all_notes = cli.notes(db)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")
  puts ""

  notes_with_html = all_notes.select { |note| DeckStatus.needs_stray_html?(note) }

  puts "Notes with HTML tags in word/sentence fields: #{notes_with_html.size}"
  puts ""

  if notes_with_html.empty?
    puts "No notes need cleaning!"
    exit ScriptCLI::EXIT_OK
  end

  # Apply limit if specified
  notes_to_process = notes_with_html
  if options[:limit]
    notes_to_process = notes_to_process.take(options[:limit])
  end

  puts "Notes to process: #{notes_to_process.size}"
  puts ""

  # Statistics
  stats = {
    total: notes_to_process.size,
    updated: 0,
    errors: 0
  }

  # Process notes
  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Cleaning HTML tags:"
  puts ""

  db.transaction do
    notes_to_process.each_with_index do |note, idx|
      note_id = note[:id]
      fields = note[:fields]

      # Get original values
      original_word = fields[Kaishi::WORD_IDX] || ''
      original_furigana = fields[Kaishi::WORD_FURIGANA_IDX] || ''
      original_sentence = fields[Kaishi::SENTENCE_IDX] || ''
      original_sentence_furigana = fields[Kaishi::SENTENCE_FURIGANA_IDX] || ''

      # Strip HTML tags
      cleaned_word = DeckStatus.strip_stray_html(original_word)
      cleaned_furigana = DeckStatus.strip_stray_html(original_furigana)
      cleaned_sentence = DeckStatus.strip_stray_html(original_sentence)
      cleaned_sentence_furigana = DeckStatus.strip_stray_html(original_sentence_furigana)

      # Update fields
      fields[Kaishi::WORD_IDX] = cleaned_word
      fields[Kaishi::WORD_FURIGANA_IDX] = cleaned_furigana
      fields[Kaishi::SENTENCE_IDX] = cleaned_sentence
      fields[Kaishi::SENTENCE_FURIGANA_IDX] = cleaned_sentence_furigana

      # Build change description
      changes = []
      changes << "Word: #{original_word} → #{cleaned_word}" if original_word != cleaned_word
      changes << "Furigana: #{original_furigana} → #{cleaned_furigana}" if original_furigana != cleaned_furigana
      changes << "Sentence: #{original_sentence} → #{cleaned_sentence}" if original_sentence != cleaned_sentence
      changes << "SentFurigana: #{original_sentence_furigana} → #{cleaned_sentence_furigana}" if original_sentence_furigana != cleaned_sentence_furigana

      change_desc = changes.join('; ')

      if options[:dry_run]
        ProgressReporter.progress(idx + 1, stats[:total], "#{change_desc} [DRY RUN]")
      else
        if db.update_note(note_id, fields)
          ProgressReporter.progress(idx + 1, stats[:total], change_desc)
          stats[:updated] += 1
        else
          ProgressReporter.progress(idx + 1, stats[:total], "#{original_word} ✗ Update failed")
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
  puts "  Updated:              #{stats[:updated]}" unless options[:dry_run]
  puts "  Errors:               #{stats[:errors]}"
  puts "=" * 70
  puts ""

  if options[:dry_run]
    puts "This was a dry run. No changes were made to the database."
    puts "Run without --dry-run to apply changes."
  elsif stats[:updated] > 0
    ProgressReporter.success("Successfully cleaned #{stats[:updated]} notes!")
  end

  # Exit with appropriate code
  exit(stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
