#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds English translations for untranslated sentence fields in Anki cards.
# Translates via an LLM CLI (OpenCode by default; see --provider for Claude or
# Google Translate) — Google's free translate_a/single endpoint now appears to
# be permanently blocked/paywalled, so it's no longer the default.
#
# Usage: add-sentence-meanings.rb [options]

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/google_translate_client'
require_relative 'lib/translator_factory'
require_relative 'lib/progress_reporter'

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
  opts.banner = "Usage: add-sentence-meanings.rb [options]"
  opts.separator ""
  opts.separator "Generates English translations for sentence fields."
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

  opts.on("--force", "Overwrite existing sentence meanings") do
    options[:force] = true
  end

  opts.on("--provider PROVIDER", "Translation provider: opencode, claude, or google (default: opencode)") do |p|
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

  # Filter notes that need translation
  notes_to_process = all_notes.select do |note|
    sentence = note[:fields][Kaishi::SENTENCE_IDX] || ''
    sentence_meaning = note[:fields][Kaishi::SENTENCE_MEANING_IDX] || ''

    has_sentence = !sentence.strip.empty?
    needs_translation = sentence_meaning.strip.empty? || options[:force]

    has_sentence && needs_translation
  end

  if options[:limit]
    notes_to_process = notes_to_process.take(options[:limit])
  end

  puts "Notes to process: #{notes_to_process.size}"
  puts ""

  if notes_to_process.empty?
    puts "No notes to process!"
    puts ""
    puts "Note: Use --force to regenerate existing translations" unless options[:force]
    exit 0
  end

  # Statistics
  stats = {
    total: notes_to_process.size,
    translated: 0,
    skipped: 0,
    updated: 0,
    errors: 0
  }

  translator = begin
    TranslatorFactory.build(options[:provider], options[:model], deck_name: options[:target_deck])
  rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
    ProgressReporter.error(e.message)
    exit 1
  end
  puts "Translation provider: #{options[:provider]}#{" (#{options[:model]})" if options[:model]}"
  puts ""

  # Cache translations by original sentence. When multiple words are mined from
  # the same sentence, the sentence field is identical across cards, so we only
  # need to call the translator once per distinct sentence.
  translation_cache = {}

  # Process notes
  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  db.transaction do
    notes_to_process.each_with_index do |note, idx|
      note_id = note[:id]
      fields = note[:fields]

      word = fields[Kaishi::WORD_IDX] || ''
      sentence = fields[Kaishi::SENTENCE_IDX] || ''

      begin
        if translation_cache.key?(sentence)
          translation = translation_cache[sentence]
          cache_status = "cache hit"
        else
          translation = translator.translate(sentence)
          translation_cache[sentence] = translation
          cache_status = "cache miss"
        end

        if translation.nil? || translation.strip.empty?
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} - Skipped (empty translation)")
          stats[:skipped] += 1
          next
        end

        fields[Kaishi::SENTENCE_MEANING_IDX] = translation
        stats[:translated] += 1

        if options[:dry_run]
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} [DRY RUN]")
          puts "   JA: #{sentence}"
          puts "   EN: #{translation}"
          puts ""
        else
          if db.update_note(note_id, fields)
            ProgressReporter.progress(idx + 1, stats[:total], "#{word} - Updated (#{cache_status})")
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
  puts "  Translated:        #{stats[:translated]}"
  puts "  Skipped:           #{stats[:skipped]}"
  puts "  Updated:           #{stats[:updated]}" unless options[:dry_run]
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
