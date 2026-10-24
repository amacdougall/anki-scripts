#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/jmdict'

# The "already processed" signal. DeckStatus also recognizes the HTML-comment
# markers earlier runs wrote, so those notes aren't reprocessed.
GRAMMAR_TAG = DeckStatus::GRAMMAR_TAG

GRAMMAR_SEPARATOR = '、'

# Strip ruby tags from text, keeping only the base characters (not furigana)
# e.g., "<ruby>食<rt>た</rt></ruby>べる" => "食べる"
def strip_ruby_tags(text)
  text.gsub(/<rt>[^<]*<\/rt>/, '')      # Remove furigana
      .gsub(/<\/?(?:ruby|rp)[^>]*>/, '') # Remove ruby/rp tags
end

# Derive grammar note labels from a JMdict entry. Reads JMdict's part-of-speech
# and misc codes (e.g. "vt", "adj-na", "on-mim") and labels them with Japanese
# grammar terms, using school-grammar names for adjectives (形容動詞 / 形容詞).
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
      notes << '他動詞（する）'
    elsif has_intransitive
      notes << '自動詞（する）'
    end
  elsif has_transitive && !has_suru
    # Regular transitive verb
    notes << '他動詞'
  elsif has_intransitive && !has_suru
    # Regular intransitive verb
    notes << '自動詞'
  end

  # Adjectives
  notes << '形容動詞' if pos.include?('adj-na')
  notes << '形容詞' if pos.include?('adj-i')

  # Adverbs. Plain "adv" says nothing about which particle (if any) follows.
  notes << '副詞（と）' if pos.include?('adv-to')
  notes << '副詞' if pos.include?('adv') && !pos.include?('adv-to')

  # Counter
  notes << '助数詞' if pos.include?('ctr')

  # Prefix/Suffix
  notes << '接頭辞' if pos.include?('pref')
  notes << '接尾辞' if pos.include?('suf')

  # Special tags. JMdict's single "on-mim" code doesn't separate 擬音語 from
  # 擬態語, so オノマトペ covers both.
  notes << 'オノマトペ' if misc.include?('on-mim')
  notes << '尊敬語' if misc.include?('hon')
  notes << '謙譲語' if misc.include?('hum')
  notes << '丁寧語' if misc.include?('pol')

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
    grammar_text = grammar_notes.join(GRAMMAR_SEPARATOR)
    fields[Kaishi::NOTES_IDX] = if existing_notes.strip.empty?
                                  grammar_text
                                else
                                  "#{grammar_text} #{existing_notes}"
                                end
    db.update_note(note_id, fields)
  end

  db.add_tags(note_id, GRAMMAR_TAG)
end

def main
  cli = ScriptCLI.new(
    'add-jmdict-grammar-notes.rb',
    'Adds grammar notes from JMdict (transitivity, adjective type, counter, onomatopoeia,',
    'honorific...) to the Notes field.'
  )
  options = cli.options
  cli.dry_run
  cli.limit
  cli.force('Re-process notes already marked as processed')
  cli.on('--ruby-only', 'Only process notes with <ruby> tags in the Word field') { options[:ruby_only] = true }
  cli.parse!

  db = cli.connect!

  begin
    notes = cli.notes(db).select do |note|
      next false if options[:ruby_only] && !note[:fields][Kaishi::WORD_IDX].to_s.include?('<ruby>')

      options[:force] || DeckStatus.needs_grammar_notes?(note)
    end
    notes = notes.take(options[:limit]) if options[:limit]
    puts "Notes to process: #{notes.length}"

    updated_count = 0
    no_grammar_count = 0

    process_notes = lambda do
      notes.each do |note|
        fields = note[:fields]
        word = fields[Kaishi::WORD_IDX] || ''
        existing_notes = fields[Kaishi::NOTES_IDX] || ''

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
          puts "  Adding: #{grammar_notes.join(GRAMMAR_SEPARATOR)}"

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
    puts "No grammar info: #{no_grammar_count}"

  ensure
    db.close
  end
end

main if __FILE__ == $PROGRAM_NAME
