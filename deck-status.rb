#!/usr/bin/env ruby
# frozen_string_literal: true

# Reports, per deck, how many Kaishi cards still need each step of the
# workflow: an example sentence, meanings, furigana, pitch accent, audio and so
# on. Uses the same checks the scripts use to pick their notes (lib/deck_status.rb),
# so each count is what that script would process now. Read-only.
#
# --json also lists the decks holding Takoboto notes (takoboto_decks), the
# source decks pull-from-takoboto.rb can pull from.

require 'json'
require_relative 'lib/script_cli'
require_relative 'lib/deck_status'

TAKOBOTO_NOTE_TYPE = 'jp.takoboto'

cli = ScriptCLI.new(
  'deck-status.rb',
  'Counts the Kaishi cards in each deck that still need work, per step.',
  "Without --target-deck, covers every deck with Kaishi cards except '#{ScriptCLI::CURATED_DECK}'.",
  deck: :optional
)
options = cli.options
options[:json] = false
cli.on('--json', 'Print JSON (for other tools) instead of a report') { options[:json] = true }
cli.parse!

db = cli.connect!(quiet: true)

begin
  deck = options[:target_deck]
  notes = db.notes_in_deck_with_deck(deck, note_type: Kaishi::NOTE_TYPE_NAME,
                                           exclude_deck: deck ? nil : ScriptCLI::CURATED_DECK)
  by_deck = deck ? { deck => notes } : notes.group_by { |note| note[:deck] }
  decks = by_deck.sort.map do |name, deck_notes|
    counts = DeckStatus.counts(deck_notes)
    { name: name, total: counts.delete(:total), needs_work: counts.delete(:needs_work), counts: counts }
  end

  if options[:json]
    checks = DeckStatus::CHECKS.map(&:to_h)
    takoboto = db.note_counts_by_deck(TAKOBOTO_NOTE_TYPE).sort.map { |name, count| { name: name, count: count } }
    puts JSON.pretty_generate(checks: checks, decks: decks, takoboto_decks: takoboto)
    exit ScriptCLI::EXIT_OK
  end

  label_width = DeckStatus::CHECKS.map { |check| check.label.length }.max
  decks.each do |d|
    pending = DeckStatus::CHECKS.reject { |check| d[:counts][check.key].zero? }
    puts "#{d[:name]}  (#{d[:total]} cards)#{pending.empty? ? ': complete' : ''}"
    pending.each do |check|
      puts format("  %-#{label_width}s  %5d  %s", check.label, d[:counts][check.key], check.script)
    end
  end
  puts 'No Kaishi cards found.' if decks.empty?
ensure
  db.close
end
