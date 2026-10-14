#!/usr/bin/env ruby
# frozen_string_literal: true

# Fills in the Word Meaning field for Anki cards that don't already have one,
# looking each word up in JMdict (with an LLM translation fallback). Intended for
# cards added by an ebook reader that only populates Word and Word Reading, but
# general-purpose. When a card's Word Reading is empty, it's backfilled from the
# lookup too. Follows the same pattern as add-sentence-meanings.rb.
#
# Usage: add-meanings.rb [options]

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/card_creator'
require_relative 'lib/word_lookup'
require_relative 'lib/progress_reporter'
require_relative 'lib/translator_factory'

# Note type to target across all decks
NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME

# Parse command-line arguments
options = {
  target_deck: nil,
  dry_run: false,
  limit: nil,
  force: false,
  provider: 'opencode',
  model: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: add-meanings.rb [options]"
  opts.separator ""
  opts.separator "Fills empty Word Meaning fields by looking the word up in JMdict"
  opts.separator "(falling back to an LLM translation, see --provider). Backfills Word Reading when empty."
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

  opts.on("--limit N", Integer, "Process only first N notes") do |n|
    options[:limit] = n
  end

  opts.on("--force", "Overwrite existing word meanings") do
    options[:force] = true
  end

  opts.on("--provider PROVIDER", "Dictionary-fallback translation provider: opencode, claude, or google (default: opencode)") do |p|
    options[:provider] = p
  end

  opts.on("-m", "--model MODEL", "Model name for claude/opencode provider (default: #{LlmDefaults::TRANSLATION['claude']} / #{LlmDefaults::TRANSLATION['opencode']})") do |m|
    options[:model] = m
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
    unless db.find_deck_id(options[:target_deck])
      ProgressReporter.error("Deck not found: #{options[:target_deck]}")
      exit 1
    end

    puts "Targeting deck: #{options[:target_deck]}"
    all_notes = db.notes_in_deck(options[:target_deck], note_type: NOTE_TYPE_NAME)
  else
    puts "Targeting all decks except '#{NOTE_TYPE_NAME}'"
    all_notes = db.notes_in_deck(nil, note_type: NOTE_TYPE_NAME, exclude_deck: NOTE_TYPE_NAME)
  end

  ProgressReporter.success("Found #{all_notes.size} notes with note type '#{NOTE_TYPE_NAME}'")
  puts ""

  # Filter notes that need a meaning
  notes_to_process = all_notes.select do |note|
    word = note[:fields][Kaishi::WORD_IDX] || ''
    meaning = note[:fields][Kaishi::WORD_MEANING_IDX] || ''

    has_word = !word.strip.empty?
    needs_meaning = meaning.strip.empty? || options[:force]

    has_word && needs_meaning
  end

  if options[:limit]
    notes_to_process = notes_to_process.take(options[:limit])
  end

  puts "Notes to process: #{notes_to_process.size}"
  puts ""

  if notes_to_process.empty?
    puts "No notes to process!"
    puts ""
    puts "Note: Use --force to regenerate existing meanings" unless options[:force]
    exit 0
  end

  # Statistics
  stats = {
    total: notes_to_process.size,
    updated: 0,
    skipped: 0,
    errors: 0
  }

  translator = begin
    TranslatorFactory.build(options[:provider], options[:model], deck_name: options[:target_deck])
  rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
    ProgressReporter.error(e.message)
    exit 1
  end
  puts "Dictionary-fallback provider: #{options[:provider]}#{" (#{options[:model]})" if options[:model]}"
  puts ""

  # Process notes
  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  db.transaction do
    notes_to_process.each_with_index do |note, idx|
      note_id = note[:id]
      fields = note[:fields]

      word = fields[Kaishi::WORD_IDX] || ''
      # The Word field may carry <ruby> furigana; query JMdict with plain kanji.
      query_word = CardCreator.strip_ruby_tags(word)
      reading = (fields[Kaishi::WORD_READING_IDX] || '').strip

      begin
        result = WordLookup.resolve(query_word, known_reading: reading.empty? ? nil : reading, verbose: true, provider: translator)
        meaning = result[:meaning]

        if meaning.nil? || meaning.strip.empty?
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} - Skipped (no meaning found)")
          stats[:skipped] += 1
          next
        end

        fields[Kaishi::WORD_MEANING_IDX] = meaning
        # Backfill the reading only when the card didn't already have one.
        backfilled_reading = nil
        if reading.empty? && !result[:reading].strip.empty?
          fields[Kaishi::WORD_READING_IDX] = result[:reading]
          backfilled_reading = result[:reading]
        end

        if options[:dry_run]
          label = backfilled_reading ? "#{word} [DRY RUN, reading → #{backfilled_reading}]" : "#{word} [DRY RUN]"
          ProgressReporter.progress(idx + 1, stats[:total], label)
          puts "   Meaning: #{meaning.gsub("\n", "\n            ")}"
          puts ""
          stats[:updated] += 1
        else
          if db.update_note(note_id, fields)
            label = backfilled_reading ? "#{word} - Updated (+reading #{backfilled_reading})" : "#{word} - Updated"
            ProgressReporter.progress(idx + 1, stats[:total], label)
            stats[:updated] += 1
          else
            ProgressReporter.progress(idx + 1, stats[:total], "#{word} - Update failed")
            stats[:errors] += 1
          end
        end

      rescue GoogleTranslateClient::RateLimitError => e
        ProgressReporter.error("Rate limit hit: #{e.message}")
        ProgressReporter.error("Stopping to avoid further rate limiting. #{stats[:updated]} notes were updated before this error.")
        break
      rescue StandardError => e
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} - Error: #{e.message}")
        stats[:errors] += 1
      end
    end
  end

  # Display summary
  puts ""
  puts "=" * 70
  puts "SUMMARY"
  puts "=" * 70
  puts "  Total notes:       #{stats[:total]}"
  puts "  Updated:           #{stats[:updated]}"
  puts "  Skipped:           #{stats[:skipped]}"
  puts "  Errors:            #{stats[:errors]}"
  puts "=" * 70
  puts ""

  if options[:dry_run]
    puts "This was a dry run. No changes were made to the database."
    puts "Run without --dry-run to apply changes."
  elsif stats[:updated] > 0
    ProgressReporter.success("Successfully updated #{stats[:updated]} notes!")
  end

  exit(stats[:errors] > 0 ? 1 : 0)

ensure
  db.close
end
