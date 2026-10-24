#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: rewrites the English grammar labels earlier runs of
# add-jmdict-grammar-notes.rb wrote ("vt.する, Onomatopoeia") into the Japanese
# labels it writes now ("他動詞（する）、オノマトペ"), and strips the
# "<!-- jisho-grammar -->" / "<!-- jmdict-grammar -->" markers those runs left.
# The generated::grammar tag marks a note as processed now; a marked note
# without it gets it.
#
# Only a run of labels at the very start of the Notes field is rewritten. Each
# old label came from exactly one JMdict code, so this is a straight text swap
# with no dictionary lookups. "に adv." becomes 副詞: it was only ever written
# for JMdict's plain "adv" code, which names no particle.
#
# A marker that separated the labels from hand-written text becomes "; ", the
# usual separator; elsewhere it's dropped along with the space around it. The
# hand-written text itself never changes: the script refuses to write a note
# whose text differs once markers, spaces, &nbsp; and semicolons are ignored.
#
# The dry run sorts notes into three groups:
#   plain        labels and markers only
#   hand-edited  other text too; shown in full to check. Text that runs straight
#                on from the labels (no marker or "; " between them) is listed
#                first, and any old label left inside the hand-written text is
#                flagged for fixing by hand
#   skipped      an old label appears but not as the leading run, and no marker
#                or tag shows the grammar script wrote it; left untouched
#
# Usage: ruby scripts/migrate-grammar-labels.rb --target-deck DECK --dry-run

require_relative '../lib/script_cli'
require_relative '../lib/deck_status'

# Longer labels first, so "vt.する" wins over "vt.".
LABELS = {
  'vt.する' => '他動詞（する）',
  'vi.する' => '自動詞（する）',
  'vt.' => '他動詞',
  'vi.' => '自動詞',
  'な adj.' => '形容動詞',
  'い adj.' => '形容詞',
  'と adv.' => '副詞（と）',
  'に adv.' => '副詞',
  'Counter' => '助数詞',
  'Prefix' => '接頭辞',
  'Suffix' => '接尾辞',
  'Onomatopoeia' => 'オノマトペ',
  'Honorific' => '尊敬語',
  'Humble' => '謙譲語',
  'Polite' => '丁寧語'
}.freeze

OLD_SEPARATOR = ', '
NEW_SEPARATOR = '、'

# A label must end at a word boundary, so "Prefixed" or "Counter-" don't count.
LABEL = /(?:#{Regexp.union(LABELS.keys).source})(?=\z|[\s,;.<&\/])/
LEADING_LABELS = /\A#{LABEL.source}(?:#{OLD_SEPARATOR}#{LABEL.source})*/

MARKER = Regexp.union(DeckStatus::GRAMMAR_MARKERS)
# One or more markers in a row, with the space around them.
MARKER_RUN = /(?:\s|&nbsp;)*(?:(?:#{MARKER.source})(?:\s|&nbsp;)*)+/

# What's left of a note with no hand-written text (e.g. voice markers).
MARKUP_ONLY = /\A(?:\s|&nbsp;|<!--.*?-->)*\z/m
# Hand-written text normally starts after a marker or "; ".
RUNS_STRAIGHT_ON = /\A(?:\s|&nbsp;)*(?!<!--|;)\S/

Change = Struct.new(:note, :word, :before, :after, :labels, :rest, :add_tag, keyword_init: true)

def translate(labels)
  labels.split(OLD_SEPARATOR).map { |label| LABELS.fetch(label) }.join(NEW_SEPARATOR)
end

# Strips markers from +text+, the part of the field after its labels (if
# +labels+) or the whole field. A marker right after the labels and before
# hand-written text becomes "; ".
def strip_markers(text, labels:)
  text.gsub(MARKER_RUN) do
    before = Regexp.last_match.pre_match
    after = Regexp.last_match.post_match
    if (before.empty? && !labels) || after.empty? || after.start_with?(';')
      ''
    elsif after.start_with?('<!--')
      ' '
    elsif before.empty?
      '; '
    else
      ' '
    end
  end
end

# The hand-written text, ignoring what strip_markers may change around it.
def substance(text)
  text.gsub(MARKER, '').gsub(/\s|&nbsp;|;/, '')
end

def show(change)
  puts "  #{change.word} (note #{change.note[:id]})#{' [adds tag]' if change.add_tag}"
  puts "    before: #{change.before.inspect}"
  puts "    after:  #{change.after.inspect}" if change.after
  puts '    ! old label left in the hand-written text' if change.rest&.match?(LABEL)
end

def main
  cli = ScriptCLI.new(
    'migrate-grammar-labels.rb',
    'One-off: rewrites English grammar labels in the Notes field into the',
    'Japanese labels add-jmdict-grammar-notes.rb now writes, and strips the',
    'old grammar markers.'
  )
  options = cli.options
  cli.dry_run
  cli.limit
  cli.on('--verbose', 'Also list every plain (labels-only) change') { options[:verbose] = true }
  cli.parse!

  db = cli.connect!

  plain = []
  hand_edited = []
  skipped = []

  cli.notes(db).each do |note|
    field = note[:fields][Kaishi::NOTES_IDX].to_s
    marked = field.match?(MARKER)
    next unless marked || field.match?(LABEL)

    word = note[:fields][Kaishi::WORD_IDX].to_s.gsub(/<rt>[^<]*<\/rt>|<[^>]+>/, '')
    tagged = note[:tags].include?(DeckStatus::GRAMMAR_TAG)
    match = field.match(LEADING_LABELS)

    unless marked || (match && tagged)
      skipped << Change.new(note: note, word: word, before: field)
      next
    end

    labels = match ? translate(match[0]) : ''
    rest = match ? match.post_match : field
    new_rest = strip_markers(rest, labels: !labels.empty?)
    raise "Rewrite changed the hand-written text: #{field.inspect}" unless substance(new_rest) == substance(rest)

    change = Change.new(note: note, word: word, before: field, after: labels + new_rest,
                        labels: labels, rest: rest, add_tag: !tagged)
    (rest.gsub(MARKER, '').match?(MARKUP_ONLY) ? plain : hand_edited) << change
  end

  changes = plain + hand_edited
  changes = changes.take(options[:limit]) if options[:limit]

  if options[:verbose]
    puts "\n=== Plain (#{plain.length}) ==="
    plain.each { |c| puts "  #{c.word}: #{c.before.inspect} => #{c.after.inspect}" }
  end

  straight_on, usual = hand_edited.partition { |c| !c.labels.empty? && c.rest.match?(RUNS_STRAIGHT_ON) }
  leftover = hand_edited.count { |c| c.rest.match?(LABEL) }
  untagged = changes.count(&:add_tag)

  puts "\n=== Hand-edited, text runs straight on from the labels: check these (#{straight_on.length}) ==="
  straight_on.each { |c| show(c) }

  puts "\n=== Hand-edited, after a marker or '; ' (#{usual.length}) ==="
  usual.each { |c| show(c) }

  puts "\n=== Skipped, not changed (#{skipped.length}) ==="
  skipped.each { |c| show(c) }

  updated = 0
  failed = 0
  unless options[:dry_run]
    changes.each do |change|
      fields = change.note[:fields].dup
      fields[Kaishi::NOTES_IDX] = change.after
      # Tag first, so a note never loses its marker without gaining the tag.
      db.add_tags(change.note[:id], DeckStatus::GRAMMAR_TAG) if change.add_tag
      if db.update_note(change.note[:id], fields)
        updated += 1
      else
        failed += 1
      end
    end
  end

  puts "\n=== Summary#{' (DRY RUN)' if options[:dry_run]} ==="
  puts "Plain: #{plain.length}"
  puts "Hand-edited: #{hand_edited.length} (#{straight_on.length} run straight on, " \
       "#{leftover} with an old label left in the text)"
  puts "Skipped: #{skipped.length}"
  puts "#{options[:dry_run] ? 'Would tag' : 'Tagged'}: #{untagged}"
  if options[:dry_run]
    puts "Would update: #{changes.length}"
  else
    puts "Updated: #{updated}"
    puts "Failed: #{failed}" if failed.positive?
  end
ensure
  db&.close
end

main if __FILE__ == $PROGRAM_NAME
