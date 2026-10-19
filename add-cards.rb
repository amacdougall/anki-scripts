#!/usr/bin/env ruby
# frozen_string_literal: true

# Batch-add vocabulary cards to an Anki deck from a YAML file.
#
# Usage: add-cards.rb [--target-deck DECK] [options] INPUT_FILE
#
# Input YAML format:
#   ---
#   target_deck: 専門用語
#   entries:
#     - word: 食べる
#     - word: 完了
#       word_meaning: conclusion
#     - word: 教材
#       sentence: 日本語学習の教材を...
#       sentence_meaning: Thank you for...
#       note: (from email)

require 'yaml'
require_relative 'lib/script_cli'
require_relative 'lib/card_creator'
require_relative 'lib/dedup_checker'
require_relative 'lib/word_lookup'
require_relative 'lib/mecab_controller'
require_relative 'lib/translator_factory'

def contains_kanji?(text)
  text.match?(/[一-鿿㐀-䶿]/)
end

# --- CLI ---

cli = ScriptCLI.new(
  'add-cards.rb',
  'Batch-adds vocabulary cards to an Anki deck from a YAML file. The deck comes from',
  "--target-deck or the file's target_deck:, and must already exist.",
  deck: :optional, usage: '[--target-deck DECK] [options] INPUT_FILE'
)
cli.dry_run('Preview the dictionary lookups without adding cards')
cli.llm(:word_meaning, providers: %w[claude opencode google], help: 'Fallback translation provider')
options = cli.parse!

input_file = ARGV[0]
cli.usage_error('INPUT_FILE is required') unless input_file

unless File.exist?(input_file)
  warn "Error: File not found: #{input_file}"
  exit ScriptCLI::EXIT_ERROR
end

# --- Load YAML ---

data = YAML.load_file(input_file)
entries = data['entries']

unless entries.is_a?(Array) && !entries.empty?
  warn "Error: YAML file must contain a non-empty 'entries' array"
  exit ScriptCLI::EXIT_ERROR
end

deck_name = options[:target_deck] || data['target_deck']
cli.usage_error('No deck specified. Use --target-deck or set target_deck in the YAML file.') unless deck_name
if deck_name == ScriptCLI::CURATED_DECK
  cli.usage_error("'#{deck_name}' is the curated source deck; scripts don't modify it")
end
options[:target_deck] = deck_name

puts "Input file:   #{input_file}"
puts "Target deck:  #{deck_name}"
puts "Entries:      #{entries.length}"
puts ""

# Validate all entries have a word
entries.each_with_index do |entry, i|
  unless entry['word'] && !entry['word'].strip.empty?
    warn "Error: Entry #{i + 1} is missing required 'word' field"
    exit ScriptCLI::EXIT_ERROR
  end
end

# --- Check Anki and the deck before the lookups (skipped for a dry run, which
# only previews them) ---

db = cli.connect! unless options[:dry_run]

# --- Dictionary lookups (before DB operations) ---

translator = begin
  TranslatorFactory.build(options[:provider], options[:model], task: :word_meaning, deck_name: deck_name)
rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
  ProgressReporter.error(e.message)
  exit ScriptCLI::EXIT_ERROR
end
puts "Dictionary-fallback provider: #{options[:provider]}#{" (#{options[:model]})" if options[:model]}"
puts ""

mecab = nil

lookup_results = {}
entries.each_with_index do |entry, i|
  word = entry['word']
  print "[#{i + 1}/#{entries.length}] Processing: #{word}... "

  reading = entry['reading']
  meaning = entry['word_meaning']
  usually_kana = false

  if reading && meaning
    puts "reading and meaning provided"
  else
    puts "performing dictionary lookup"
    begin
      result = WordLookup.resolve(word, known_reading: reading, verbose: true, provider: translator)
      reading = result[:reading] if reading.nil? || reading.strip.empty?
      meaning = result[:meaning] if meaning.nil? || meaning.strip.empty?
      usually_kana = result[:usually_kana]
    rescue GoogleTranslateClient::RateLimitError, LLMInterface::UsageLimitError => e
      ScriptCLI.limit_reached!("Stopped by a rate or usage limit before adding any cards: #{e.message[0, 200]}")
    rescue StandardError => e
      ProgressReporter.warning("Lookup failed for '#{word}': #{e.message}")
    end
  end

  reading ||= WordLookup.all_kana?(word) ? word : ''
  meaning ||= ''

  # When JMdict marks the word as usually written in kana alone but it contains
  # kanji, render the word with <ruby> furigana so the card displays the kana
  # form prominently while preserving the kanji. The "word" field doesn't
  # render bracket notation, so MeCab output must be converted to ruby tags.
  display_word = word
  if usually_kana && contains_kanji?(word) && !reading.strip.empty?
    mecab ||= MecabController.new
    begin
      bracket = mecab.generate_furigana(word, preferred_reading: reading)
      display_word = CardCreator.bracket_to_ruby(bracket) unless bracket.strip.empty?
    rescue StandardError => e
      ProgressReporter.warning("Failed to generate ruby furigana for '#{word}': #{e.message}")
    end
  end

  lookup_results[i] = {
    reading: reading,
    meaning: meaning,
    usually_kana: usually_kana,
    display_word: display_word
  }
end

puts ""

# --- Preview ---

entries.each_with_index do |entry, i|
  word = entry['word']
  lr = lookup_results[i]
  puts "#{i + 1}. #{word}"
  puts "   Reading: #{lr[:reading]}"
  puts "   Meaning: #{lr[:meaning].gsub("\n", "\n            ")}"
  puts "   Sentence: #{entry['sentence'] || '(none)'}"
  puts "   Display:  #{lr[:display_word]} (usually kana)" if lr[:display_word] != word
  puts ""
end

if options[:dry_run]
  puts "Dry run — no changes made."
  exit ScriptCLI::EXIT_OK
end

# --- Add the cards ---

stats = { created: 0, skipped_duplicate: 0, errors: 0 }

begin
  # Dedup against every deck using the Kaishi 1.5k note type, not just
  # deck_name — the same word being added to a staging deck shouldn't
  # duplicate one already sitting in, say, Kaishi 1.5k itself. Key is
  # (word, reading), with ruby tags stripped so dedup matches across both
  # plain and ruby-tagged forms of the same vocab. This compound dedup is more
  # precise than Anki's first-field-only check, so we add with
  # allow_duplicate and rely on it.
  dedup = DedupChecker.new(db)

  entries.each_with_index do |entry, i|
    word = entry['word']

    lr = lookup_results[i]

    if dedup.duplicate?(word, lr[:reading])
      ProgressReporter.warning("Skipping '#{word}' (#{lr[:reading]}) — already exists in the collection")
      stats[:skipped_duplicate] += 1
      next
    end

    begin
      fields = CardCreator.build_fields(
        word: lr[:display_word],
        reading: lr[:reading],
        meaning: lr[:meaning],
        sentence: entry['sentence'] || '',
        sentence_meaning: entry['sentence_meaning'] || '',
        note: entry['note'] || ''
      )

      if db.add_note(deck_name, fields, allow_duplicate: true)
        dedup.add(word, lr[:reading])
        stats[:created] += 1
        ProgressReporter.success("Added '#{word}'")
      else
        ProgressReporter.error("Failed to add '#{word}'")
        stats[:errors] += 1
      end
    rescue StandardError => e
      ProgressReporter.error("Failed to add '#{word}': #{e.message}")
      stats[:errors] += 1
    end
  end

  # Summary
  total = entries.length
  puts ""
  puts "=" * 50
  puts "SUMMARY"
  puts "=" * 50
  puts "  Total entries:        #{total}"
  puts "  Created:              #{stats[:created]}"
  puts "  Skipped (duplicate):  #{stats[:skipped_duplicate]}"
  puts "  Errors:               #{stats[:errors]}"
  puts "=" * 50

  exit(stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)
ensure
  db.close
end
