#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/anki_connect'
require_relative 'lib/kaishi_fields'
require_relative 'lib/jmdict'

# Constants
NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME
# The "already processed" signal is now this Anki tag. The legacy HTML-comment
# markers below are still *read* (fallback) so notes annotated before the tag
# migration aren't reprocessed; they are no longer written.
GRAMMAR_TAG = 'generated::grammar'
GRAMMAR_MARKER = '<!-- jmdict-grammar -->'
# Marker written by earlier runs (before the JMdict switch); still recognized so
# already-annotated notes aren't reprocessed or duplicated.
LEGACY_GRAMMAR_MARKER = '<!-- jisho-grammar -->'

# Strip ruby tags from text, keeping only the base characters (not furigana)
# e.g., "<ruby>食<rt>た</rt></ruby>べる" => "食べる"
def strip_ruby_tags(text)
  text.gsub(/<rt>[^<]*<\/rt>/, '')      # Remove furigana
      .gsub(/<\/?(?:ruby|rp)[^>]*>/, '') # Remove ruby/rp tags
end

# Derive grammar note labels from a JMdict entry. Reads JMdict's part-of-speech
# and misc codes (e.g. "vt", "adj-na", "on-mim") rather than jisho.org's English
# labels, but produces the same output strings as before.
def extract_grammar_notes(entry)
  return [] unless entry

  pos = JMDict.parts_of_speech(entry) # e.g. ["v1", "vt", "n"]
  misc = JMDict.misc_tags(entry)      # e.g. ["uk", "on-mim"]

  notes = []

  # Verb types. Suru-verb codes: vs (+noun), vs-s / vs-i (special conjugations).
  has_transitive = pos.include?('vt')
  has_intransitive = pos.include?('vi')
  has_suru = (pos & %w[vs vs-s vs-i]).any?
  has_noun = pos.include?('n')

  # Suru verbs (noun + suru verb)
  if has_noun && has_suru
    if has_transitive
      notes << 'vt.する'
    elsif has_intransitive
      notes << 'vi.する'
    end
  elsif has_transitive && !has_suru
    # Regular transitive verb
    notes << 'vt.'
  elsif has_intransitive && !has_suru
    # Regular intransitive verb
    notes << 'vi.'
  end

  # Adjectives
  notes << 'な adj.' if pos.include?('adj-na')
  notes << 'い adj.' if pos.include?('adj-i')

  # Adverbs
  notes << 'と adv.' if pos.include?('adv-to')
  notes << 'に adv.' if pos.include?('adv') && !pos.include?('adv-to')

  # Counter
  notes << 'Counter' if pos.include?('ctr')

  # Prefix/Suffix
  notes << 'Prefix' if pos.include?('pref')
  notes << 'Suffix' if pos.include?('suf')

  # Special tags
  notes << 'Onomatopoeia' if misc.include?('on-mim')
  notes << 'Honorific' if misc.include?('hon')
  notes << 'Humble' if misc.include?('hum')
  notes << 'Polite' if misc.include?('pol')

  notes
end

def update_note_with_grammar(db, note_id, grammar_notes, existing_notes)
  # Prepend the grammar text (if any) to the Notes field. The "already
  # processed" signal is the generated::grammar tag added below, not an embedded
  # HTML-comment marker, so no marker is written. When there's no grammar info
  # the field is left untouched — the tag alone marks the note as processed.
  unless grammar_notes.empty?
    note = db.get_note(note_id)
    return false unless note

    fields = note[:fields]
    grammar_text = grammar_notes.join(', ')
    fields[Kaishi::NOTES_IDX] = if existing_notes.strip.empty?
                                  grammar_text
                                else
                                  "#{grammar_text} #{existing_notes}"
                                end
    db.update_note(note_id, fields)
  end

  db.add_tags(note_id, GRAMMAR_TAG)
end

def get_all_notes(db, target_deck: nil)
  if target_deck
    unless db.find_deck_id(target_deck)
      puts "Error: Deck not found: #{target_deck}"
      exit 1
    end

    puts "Targeting deck: #{target_deck}"
    db.notes_in_deck(target_deck, note_type: NOTE_TYPE_NAME)
  else
    puts "Targeting all decks except '#{NOTE_TYPE_NAME}'"
    db.notes_in_deck(nil, note_type: NOTE_TYPE_NAME, exclude_deck: NOTE_TYPE_NAME)
  end
end

def main
  # Parse command line options
  options = {
    dry_run: false,
    limit: nil,
    target_deck: nil
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"
    opts.separator ""
    opts.separator "Adds grammatical usage notes from JMdict to Anki cards."
    opts.separator "Operates on all notes using the '#{NOTE_TYPE_NAME}' note type."
    opts.separator ""
    opts.separator "Options:"

    opts.on('--limit N', Integer, 'Limit number of notes to process') do |n|
      options[:limit] = n
    end

    opts.on('--dry-run', 'Preview changes without modifying database') do
      options[:dry_run] = true
    end

    opts.on('--ruby-only', 'Only process notes with <ruby> tags in Word field') do
      options[:ruby_only] = true
    end

    opts.on('--force', 'Re-process notes even if already marked with grammar marker') do
      options[:force] = true
    end

    opts.on('--target-deck DECK', 'Target a specific deck (default: all decks except "Kaishi 1.5k")') do |deck|
      options[:target_deck] = deck
    end

    opts.on('-h', '--help', 'Display this help') do
      puts opts
      exit
    end
  end.parse!

  # Anki must be running with the AnkiConnect add-on installed.
  AnkiConnect.require_running!

  # Connect to Anki
  db = AnkiConnect.new.connect

  begin
    # Find note type ID
    note_type_id = db.find_note_type_id(NOTE_TYPE_NAME)
    unless note_type_id
      puts "Error: Note type '#{NOTE_TYPE_NAME}' not found"
      exit 1
    end

    # Fetch notes: either from a specific deck, or all except the curated source deck
    notes = get_all_notes(db, target_deck: options[:target_deck])

    # Apply limit if specified
    if options[:limit] && options[:limit] < notes.length
      puts "Found #{notes.length} notes with note type '#{NOTE_TYPE_NAME}' (limiting to #{options[:limit]})"
      notes = notes.take(options[:limit])
    else
      puts "Found #{notes.length} notes with note type '#{NOTE_TYPE_NAME}'"
    end

    updated_count = 0
    skipped_count = 0
    no_grammar_count = 0

    process_notes = lambda do
      notes.each do |note|
        fields = note[:fields]
        word = fields[Kaishi::WORD_IDX] || ''
        existing_notes = fields[Kaishi::NOTES_IDX] || ''

        # Skip if --ruby-only and word doesn't contain ruby tags
        if options[:ruby_only] && !word.include?('<ruby>')
          next
        end

        # Skip if already processed (unless --force). The generated::grammar tag
        # is the current signal; the legacy HTML-comment markers are recognized
        # as a fallback so notes annotated before the migration aren't redone.
        already_processed = note[:tags]&.include?(GRAMMAR_TAG) ||
                            existing_notes.include?(GRAMMAR_MARKER) ||
                            existing_notes.include?(LEGACY_GRAMMAR_MARKER)
        if already_processed && !options[:force]
          skipped_count += 1
          next
        end

        puts "Processing: #{word}"

        # Strip ruby tags for the JMdict query (e.g., "<ruby>食<rt>た</rt></ruby>べる" => "食べる")
        query_word = strip_ruby_tags(word)

        # Look the word up in JMdict, keeping only entries whose forms include
        # the queried word exactly as a written form or reading.
        entries = JMDict.entries_for(query_word)
        jmdict_entry = entries.find { |e| JMDict.entry_matches_word?(e, query_word) }

        unless jmdict_entry
          no_grammar_count += 1
          puts "  No exact JMdict entry found (marking as processed)"

          unless options[:dry_run]
            update_note_with_grammar(db, note[:id], [], existing_notes)
          end
          next
        end

        # Extract grammar notes
        grammar_notes = extract_grammar_notes(jmdict_entry)

        if grammar_notes.empty?
          no_grammar_count += 1
          puts "  No relevant grammar information found (marking as processed)"

          unless options[:dry_run]
            # Still add marker so we skip this note in future runs
            update_note_with_grammar(db, note[:id], [], existing_notes)
          end
        else
          puts "  Adding: #{grammar_notes.join(', ')}"

          unless options[:dry_run]
            # Update note
            update_note_with_grammar(db, note[:id], grammar_notes, existing_notes)
          end

          updated_count += 1
        end
      end
    end

    if options[:dry_run]
      puts "\n=== DRY RUN MODE ==="
      process_notes.call
    else
      db.transaction do
        process_notes.call
      end
    end

    puts "\n=== Summary ==="
    puts "Total notes: #{notes.length}"
    puts "#{options[:dry_run] ? 'Would update' : 'Updated'}: #{updated_count}"
    puts "Skipped (already processed): #{skipped_count}"
    puts "No grammar info: #{no_grammar_count}"

  ensure
    db.close
  end
end

main if __FILE__ == $PROGRAM_NAME
