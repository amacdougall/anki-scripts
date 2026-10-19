#!/usr/bin/env ruby
# frozen_string_literal: true

# Fills in the Word Meaning field for Anki cards that don't already have one,
# looking each word up in JMdict (with an LLM translation fallback). Intended for
# cards added by an ebook reader that only populates Word and Word Reading, but
# general-purpose. When a card's Word Reading is empty, it's backfilled from the
# lookup too. Follows the same pattern as add-sentence-meanings.rb.
#
# Usage: add-meanings.rb --target-deck DECK [options]

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/card_creator'
require_relative 'lib/word_lookup'
require_relative 'lib/translator_factory'

cli = ScriptCLI.new(
  'add-meanings.rb',
  'Fills empty Word Meaning fields by looking the word up in JMdict, falling back',
  'to an LLM translation for words JMdict lacks. Backfills an empty Word Reading too.'
)
cli.dry_run
cli.limit
cli.force('Overwrite existing word meanings')
cli.llm(:word_meaning, providers: %w[claude opencode google], help: 'Fallback translation provider')
options = cli.parse!

db = cli.connect!

begin
  all_notes = cli.notes(db)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")
  puts ""

  notes_to_process = all_notes.select do |note|
    DeckStatus.needs_word_meaning?(note) ||
      (options[:force] && !note[:fields][Kaishi::WORD_IDX].to_s.strip.empty?)
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
    exit ScriptCLI::EXIT_OK
  end

  # Statistics
  stats = {
    total: notes_to_process.size,
    updated: 0,
    skipped: 0,
    errors: 0
  }

  translator = begin
    TranslatorFactory.build(options[:provider], options[:model], task: :word_meaning, deck_name: options[:target_deck])
  rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
    ProgressReporter.error(e.message)
    exit ScriptCLI::EXIT_ERROR
  end
  puts "Dictionary-fallback provider: #{options[:provider]}#{" (#{options[:model]})" if options[:model]}"
  puts ""

  # Process notes
  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  limit_error = nil
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

      rescue GoogleTranslateClient::RateLimitError, LLMInterface::UsageLimitError => e
        limit_error = e
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

  if limit_error
    ScriptCLI.limit_reached!("Adding meanings stopped by a rate or usage limit: #{limit_error.message[0, 200]}. " \
                             "#{stats[:updated]} notes were updated first.")
  end

  exit(stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
