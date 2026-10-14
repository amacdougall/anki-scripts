#!/usr/bin/env ruby
# frozen_string_literal: true

# Exports every word you have studied (Kaishi 1.5k cards that are neither new
# nor suspended) to a text file, one per line, plus the unique kanji in those
# words to seen-kanji.txt alongside it. Read-only.
#
# Usage: export-seen-words.rb [--output FILE] [--exclude-deck DECK ...]

require 'fileutils'
require 'optparse'
require 'set'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/progress_reporter'

NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME
DEFAULT_OUTPUT = File.join(__dir__, 'data', 'seen-words.txt')

def parse_args
  options = { output: DEFAULT_OUTPUT, excluded_decks: [] }
  OptionParser.new do |opts|
    opts.banner = 'Usage: export-seen-words.rb [options]'
    opts.on('-o', '--output FILE', "Word list path (default: data/seen-words.txt); seen-kanji.txt goes alongside") do |f|
      options[:output] = f
    end
    opts.on('--exclude-deck DECK', 'Leave out a deck (repeatable)') { |d| options[:excluded_decks] << d }
    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end.parse!
  options
end

def main
  options = parse_args
  output_path = options[:output]

  AnkiConnect.require_running!
  db = AnkiConnect.new.connect

  begin
    note_type_id = db.find_note_type_id(NOTE_TYPE_NAME)
    unless note_type_id
      ProgressReporter.error("Note type '#{NOTE_TYPE_NAME}' not found")
      exit 1
    end

    # "Seen" = a card that isn't new and isn't suspended (the old type != 0 /
    # queue != -1 filter). Excluded decks are dropped at the query level; for our
    # single-card note type that matches the old "keep if any card is in a
    # non-excluded deck" behaviour.
    query = +%(note:"#{NOTE_TYPE_NAME}" -is:new -is:suspended)
    options[:excluded_decks].each { |name| query << %( -deck:"#{name}") }

    words = db.find_notes(query).map do |note|
      word = note[:fields][Kaishi::WORD_IDX] || ''
      word.gsub(/<[^>]+>/, '').strip
    end.reject(&:empty?).sort.uniq

    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, words.join("\n") + "\n")

    ProgressReporter.success("Exported #{words.size} seen words to #{output_path}")

    kanji = words.join.scan(/[一-鿿㐀-䶿]/).uniq.sort
    kanji_path = File.join(File.dirname(output_path), 'seen-kanji.txt')
    File.write(kanji_path, kanji.join("\n") + "\n")

    ProgressReporter.success("Exported #{kanji.size} unique kanji to #{kanji_path}")
  ensure
    db.close
  end
end

main if __FILE__ == $PROGRAM_NAME
