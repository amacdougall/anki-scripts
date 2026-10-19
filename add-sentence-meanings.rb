#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds English translations for untranslated sentence fields in Anki cards.
# Translates via an LLM CLI (Claude by default; see --provider for OpenCode or
# Google Translate). Google's free translate_a/single endpoint now appears to
# be permanently blocked/paywalled, so it's no longer the default.
#
# Usage: add-sentence-meanings.rb --target-deck DECK [options]

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/google_translate_client'
require_relative 'lib/translator_factory'

cli = ScriptCLI.new(
  'add-sentence-meanings.rb',
  'Translates example sentences that have no English yet. With an LLM provider, the',
  "deck's translation notes (prompts/translation/<deck>.md) and name readings are added to the prompt."
)
cli.dry_run
cli.limit
cli.force('Overwrite existing sentence meanings')
cli.llm(:sentence_translation, providers: %w[claude opencode google], help: 'Translation provider')
options = cli.parse!

db = cli.connect!

begin
  all_notes = cli.notes(db)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")
  puts ""

  notes_to_process = all_notes.select do |note|
    DeckStatus.needs_sentence_meaning?(note) ||
      (options[:force] && !note[:fields][Kaishi::SENTENCE_IDX].to_s.strip.empty?)
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
    exit ScriptCLI::EXIT_OK
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
    TranslatorFactory.build(options[:provider], options[:model], task: :sentence_translation, deck_name: options[:target_deck])
  rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
    ProgressReporter.error(e.message)
    exit ScriptCLI::EXIT_ERROR
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

  limit_error = nil
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

  if limit_error
    ScriptCLI.limit_reached!("Translation stopped by a rate or usage limit: #{limit_error.message[0, 200]}. " \
                             "#{stats[:updated]} notes were updated first.")
  end

  exit(stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
