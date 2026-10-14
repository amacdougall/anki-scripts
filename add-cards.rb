#!/usr/bin/env ruby
# frozen_string_literal: true

# Batch-add vocabulary cards to an Anki deck from a YAML file.
#
# Usage: add-cards.rb [options] INPUT_FILE
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

require 'optparse'
require 'yaml'
require_relative 'lib/anki_connect'
require_relative 'lib/card_creator'
require_relative 'lib/dedup_checker'
require_relative 'lib/word_lookup'
require_relative 'lib/kaishi_fields'
require_relative 'lib/mecab_controller'
require_relative 'lib/progress_reporter'
require_relative 'lib/translator_factory'

def contains_kanji?(text)
  text.match?(/[一-鿿㐀-䶿]/)
end

# --- CLI ---

options = {
  deck: nil,
  dry_run: false,
  provider: 'opencode',
  model: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: add-cards.rb [options] INPUT_FILE"
  opts.separator ""
  opts.separator "Batch-add vocabulary cards to an Anki deck from a YAML file."
  opts.separator ""
  opts.separator "Options:"

  opts.on("--target-deck DECK", "Override target_deck from YAML file") { |d| options[:deck] = d }
  opts.on("--dry-run", "Preview all cards without writing") { options[:dry_run] = true }
  opts.on("--provider PROVIDER", "Dictionary-fallback translation provider: opencode, claude, or google (default: opencode)") do |p|
    options[:provider] = p
  end
  opts.on("-m", "--model MODEL", "Model name for claude/opencode provider (default: #{LlmDefaults::TRANSLATION['claude']} / #{LlmDefaults::TRANSLATION['opencode']})") do |m|
    options[:model] = m
  end
  opts.on("-h", "--help", "-?", "Show this message") { puts opts; exit }
end
parser.parse!

input_file = ARGV[0]
unless input_file
  warn "Error: INPUT_FILE is required"
  warn parser.help
  exit 1
end

unless File.exist?(input_file)
  warn "Error: File not found: #{input_file}"
  exit 1
end

# --- Load YAML ---

data = YAML.load_file(input_file)
entries = data['entries']

unless entries.is_a?(Array) && !entries.empty?
  warn "Error: YAML file must contain a non-empty 'entries' array"
  exit 1
end

deck_name = options[:deck] || data['target_deck']
unless deck_name
  warn "Error: No deck specified. Use --target-deck or set target_deck in the YAML file."
  exit 1
end

puts "Input file:   #{input_file}"
puts "Target deck:  #{deck_name}"
puts "Entries:      #{entries.length}"
puts ""

# Validate all entries have a word
entries.each_with_index do |entry, i|
  unless entry['word'] && !entry['word'].strip.empty?
    warn "Error: Entry #{i + 1} is missing required 'word' field"
    exit 1
  end
end

# --- Safety check (skip for dry run, which only previews dictionary lookups) ---

AnkiConnect.require_running! unless options[:dry_run]

# --- Dictionary lookups (before DB operations) ---

translator = begin
  TranslatorFactory.build(options[:provider], options[:model], deck_name: deck_name)
rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
  ProgressReporter.error(e.message)
  exit 1
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
    rescue GoogleTranslateClient::RateLimitError => e
      ProgressReporter.error("Google Translate rate limit: #{e.message}")
      exit 3
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
  exit 0
end

# --- Connect and validate ---

db = AnkiConnect.new.connect

stats = { created: 0, skipped_duplicate: 0, errors: 0 }

begin
  unless db.find_deck_id(deck_name)
    ProgressReporter.error("Deck '#{deck_name}' not found in Anki. Please create it first.")
    exit 1
  end

  unless db.find_note_type_id(CardCreator::NOTE_TYPE_NAME)
    ProgressReporter.error("Note type '#{CardCreator::NOTE_TYPE_NAME}' not found.")
    exit 1
  end

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

ensure
  db.close
end
