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
#   pull-from-takoboto.rb --source 'Takoboto Various' --target 'My Vocab'
#
# Steps:
#   1. Read the Japanese (word) field from every jp.takoboto note in --source.
#   2. Write a temp YAML file in add-cards.rb's expected format.
#   3. Run add-cards.rb on it (which builds the cards in --target).
#   4. Prompt to clean up the tempfile and/or the source deck.
#
# Deleting the Takoboto source deck is safe: Takoboto can trivially recreate it.

require 'fileutils'
require 'optparse'
require 'yaml'
require_relative 'lib/anki_connect'
require_relative 'lib/progress_reporter'

TAKOBOTO_NOTE_TYPE = 'jp.takoboto'
TAKOBOTO_WORD_IDX = 0 # the "Japanese" field

# --- CLI ---

options = { source: nil, target: nil, provider: nil, model: nil }

parser = OptionParser.new do |opts|
  opts.banner = "Usage: pull-from-takoboto.rb --source SOURCE_DECK --target TARGET_DECK"
  opts.separator ""
  opts.separator "Pull words from a Takoboto-generated deck into a target deck."
  opts.separator ""
  opts.separator "Options:"

  opts.on("--source DECK", "Takoboto-generated source deck to pull words from") { |d| options[:source] = d }
  opts.on("--target DECK", "Target deck to add the cards to") { |d| options[:target] = d }
  opts.on("--provider PROVIDER", "Passed through to add-cards.rb: dictionary-fallback provider (google, claude, or opencode)") do |p|
    options[:provider] = p
  end
  opts.on("-m", "--model MODEL", "Passed through to add-cards.rb: model name for claude/opencode provider") { |m| options[:model] = m }
  opts.on("-h", "--help", "-?", "Show this message") { puts opts; exit }
end
parser.parse!

unless options[:source] && options[:target]
  warn "Error: both --source and --target are required"
  warn parser.help
  exit 1
end

source_deck = options[:source]
target_deck = options[:target]

# --- Connect and read words ---

AnkiConnect.require_running!
db = AnkiConnect.new.connect

unless db.find_deck_id(source_deck)
  ProgressReporter.error("Source deck '#{source_deck}' not found in Anki.")
  exit 1
end

notes = db.notes_in_deck(source_deck, note_type: TAKOBOTO_NOTE_TYPE)
words = notes.map { |note| note[:fields][TAKOBOTO_WORD_IDX].to_s.strip }.reject(&:empty?)

if words.empty?
  warn "Error: no #{TAKOBOTO_NOTE_TYPE} words found in '#{source_deck}'."
  exit 1
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
add_cards_args = [temp_file]
add_cards_args.push('--provider', options[:provider]) if options[:provider]
add_cards_args.push('--model', options[:model]) if options[:model]

unless system(add_cards, *add_cards_args)
  warn ""
  warn "add-cards.rb exited with an error; leaving the tempfile and source deck in place."
  exit 1
end

# --- Clean up ---

print "\nClean up: [t]empfile, [s]ource deck, [b]oth, e[x]it: "
choice = ($stdin.gets || '').strip.downcase

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
