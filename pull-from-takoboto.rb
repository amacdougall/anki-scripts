#!/usr/bin/env ruby
# frozen_string_literal: true

# Pull words from a Takoboto-generated Anki deck into a target deck.
#
# Takoboto (an Android dictionary app) has an Anki integration that dumps
# selected words into a deck using its own `jp.takoboto` note type. Its readings,
# meanings, and sentences aren't what we want, so this script grabs only the
# WORDS and feeds them through add-cards.rb, which re-derives everything fresh
# from JMdict (falling back to an LLM translation, see --provider) as our
# Kaishi 1.5k cards.
#
# Usage:
#   pull-from-takoboto.rb --source-deck 'Takoboto Various' --target-deck 'My Vocab'
#
# Steps:
#   1. Read the Japanese (word) field from every jp.takoboto note in --source-deck.
#   2. Write a temp YAML file in add-cards.rb's expected format.
#   3. Run add-cards.rb on it (which builds the cards in --target-deck).
#   4. Clean up the tempfile and/or the source deck, as --cleanup says or, without
#      it, as you answer at the prompt.
#
# Deleting the Takoboto source deck is safe: Takoboto can trivially recreate it.

require 'fileutils'
require 'yaml'
require_relative 'lib/script_cli'

TAKOBOTO_NOTE_TYPE = 'jp.takoboto'
TAKOBOTO_WORD_IDX = 0 # the "Japanese" field

# Answers to the clean-up step: [t]empfile, [s]ource deck, [b]oth, e[x]it.
CLEANUP_CHOICES = %w[t s b x].freeze

# --- CLI ---

cli = ScriptCLI.new(
  'pull-from-takoboto.rb',
  'Pulls the words from a Takoboto-generated deck into a target deck as new Kaishi',
  'cards, via add-cards.rb (so readings and meanings are looked up fresh).',
  usage: '--source-deck DECK --target-deck DECK [options]'
)
options = cli.options
options[:source] = nil
options[:cleanup] = nil
cli.on("--source-deck DECK", "Takoboto-generated deck to pull words from (required)") { |d| options[:source] = d }
cli.on("--cleanup CHOICE", CLEANUP_CHOICES,
       "Afterward, delete the [t]empfile, [s]ource deck, [b]oth, or e[x]it (default: ask)") do |c|
  options[:cleanup] = c
end
cli.llm(:word_meaning, providers: %w[claude opencode google], help: 'Passed to add-cards.rb: fallback translation provider')
cli.parse!

cli.usage_error('--source-deck is required') unless options[:source]

source_deck = options[:source]
target_deck = options[:target_deck]

# --- Connect and read words ---

db = cli.connect!

unless db.find_deck_id(source_deck)
  ProgressReporter.error("Source deck '#{source_deck}' not found in Anki.")
  exit ScriptCLI::EXIT_ERROR
end

notes = db.notes_in_deck(source_deck, note_type: TAKOBOTO_NOTE_TYPE)
words = notes.map { |note| note[:fields][TAKOBOTO_WORD_IDX].to_s.strip }.reject(&:empty?)

if words.empty?
  warn "Error: no #{TAKOBOTO_NOTE_TYPE} words found in '#{source_deck}'."
  exit ScriptCLI::EXIT_ERROR
end

# No pre-filtering here: dedup is word+reading (see DedupChecker), and
# Takoboto notes don't carry a reading, so an accurate check isn't possible
# until add-cards.rb's dictionary lookup determines one. It applies the real
# check — across every deck using the Kaishi 1.5k note type — before writing
# each card.

puts "Source deck:  #{source_deck}"
puts "Target deck:  #{target_deck}"
puts "Words found:  #{words.length}"
puts ""

# --- Write temp YAML in add-cards.rb's format ---

timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
temp_file = File.join(__dir__, 'temp', "takoboto-#{timestamp}.yaml")

payload = {
  'target_deck' => target_deck,
  'entries' => words.map { |word| { 'word' => word } }
}
FileUtils.mkdir_p(File.dirname(temp_file))
File.write(temp_file, payload.to_yaml)
puts "Wrote #{words.length} words to #{temp_file}"
puts ""

# --- Run add-cards.rb ---

add_cards = File.join(__dir__, 'add-cards.rb')
add_cards_args = [temp_file, '--provider', options[:provider]]
add_cards_args.push('--model', options[:model]) if options[:model]

unless system(add_cards, *add_cards_args)
  status = $?.exitstatus || ScriptCLI::EXIT_ERROR
  warn ""
  warn "add-cards.rb exited with status #{status}; leaving the tempfile and source deck in place."
  exit status
end

# --- Clean up ---

choice = options[:cleanup]
unless choice
  print "\nClean up: [t]empfile, [s]ource deck, [b]oth, e[x]it: "
  choice = ($stdin.gets || '').strip.downcase
end

case choice
when 't'
  File.delete(temp_file)
  puts "Deleted tempfile #{temp_file}."
when 's'
  db.delete_deck(source_deck)
  puts "Deleted source deck '#{source_deck}'."
when 'b'
  File.delete(temp_file)
  db.delete_deck(source_deck)
  puts "Deleted tempfile #{temp_file} and source deck '#{source_deck}'."
else
  puts "Left the tempfile and source deck in place."
end
