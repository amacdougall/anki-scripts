#!/usr/bin/env ruby

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/progress_reporter'

# Note type to target across all decks
NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME

# Parse command-line arguments
options = {
  dry_run: false,
  limit: nil,
  target_deck: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: strip-word-html.rb [options]"
  opts.separator ""
  opts.separator "Strips HTML tags from Word, Word Furigana, Sentence, and Sentence Furigana fields in Anki notes."
  opts.separator "When --target-deck is given, operates on that deck only."
  opts.separator "When omitted, operates on all decks except '#{NOTE_TYPE_NAME}'."
  opts.separator ""
  opts.separator "Options:"

  opts.on("-d", "--target-deck DECK", "Target a specific deck (default: all decks except '#{NOTE_TYPE_NAME}')") do |deck|
    options[:target_deck] = deck
  end

  opts.on("--dry-run", "Preview changes without modifying database") do
    options[:dry_run] = true
  end

  opts.on("--limit N", Integer, "Process only first N notes with HTML") do |n|
    options[:limit] = n
  end

  opts.on("-h", "--help", "-?", "Show this message") do
    puts opts
    exit
  end
end.parse!

# Strip HTML tags from text
def strip_html_tags(text)
  # Remove all HTML tags except ruby, rt, and rp tags (used for furigana)
  text.gsub(/<(?!\/?(?:ruby|rt|rp)\b)[^>]+>/, '')
end

# Check if text contains HTML tags
def has_html_tags?(text)
  text.match?(/<[^>]+>/)
end

# Anki must be running with the AnkiConnect add-on installed.
AnkiConnect.require_running!
ProgressReporter.success("Connected to Anki via AnkiConnect")
puts ""

db = AnkiConnect.new.connect

begin
  # Find note type ID
  puts "Finding note type: #{NOTE_TYPE_NAME}"
  note_type_id = db.find_note_type_id(NOTE_TYPE_NAME)

  unless note_type_id
    ProgressReporter.error("Note type not found: #{NOTE_TYPE_NAME}")
    exit 1
  end

  if options[:target_deck]
    # Target a specific deck
    unless db.find_deck_id(options[:target_deck])
      ProgressReporter.error("Deck not found: #{options[:target_deck]}")
      exit 1
    end

    puts "Targeting deck: #{options[:target_deck]}"
    all_notes = db.notes_in_deck(options[:target_deck], note_type: NOTE_TYPE_NAME)
  else
    # All decks except the curated source deck
    puts "Targeting all decks except '#{NOTE_TYPE_NAME}'"
    all_notes = db.notes_in_deck(nil, note_type: NOTE_TYPE_NAME, exclude_deck: NOTE_TYPE_NAME)
  end

  ProgressReporter.success("Found #{all_notes.size} notes with note type '#{NOTE_TYPE_NAME}'")
  puts ""

  # Filter notes that have HTML in word or sentence fields
  notes_with_html = all_notes.select do |note|
    word = note[:fields][Kaishi::WORD_IDX] || ''
    word_furigana = note[:fields][Kaishi::WORD_FURIGANA_IDX] || ''
    sentence = note[:fields][Kaishi::SENTENCE_IDX] || ''
    sentence_furigana = note[:fields][Kaishi::SENTENCE_FURIGANA_IDX] || ''
    has_html_tags?(word) || has_html_tags?(word_furigana) ||
      has_html_tags?(sentence) || has_html_tags?(sentence_furigana)
  end

  puts "Notes with HTML tags in word/sentence fields: #{notes_with_html.size}"
  puts ""

  if notes_with_html.empty?
    puts "No notes need cleaning!"
    exit 0
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
    furigana_only: 0,
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
      cleaned_word = strip_html_tags(original_word)
      cleaned_furigana = strip_html_tags(original_furigana)
      cleaned_sentence = strip_html_tags(original_sentence)
      cleaned_sentence_furigana = strip_html_tags(original_sentence_furigana)

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

      if changes.empty?
        # HTML was furigana tags only — no stripping needed, count silently
        stats[:furigana_only] += 1
        next
      end

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
  puts "  Furigana tags only:   #{stats[:furigana_only]}"
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
  exit(stats[:errors] > 0 ? 1 : 0)

ensure
  db.close
end
