#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/script_cli'
require_relative 'lib/frequency_database'

# Reorder the *unseen* ("new") Kaishi 1.5k cards in a deck so the most common
# words come up first, using JPDB v2 frequency ranks (lower rank = more common;
# see lib/frequency_database.rb).
#
# It only permutes the cards among the new-queue positions they already occupy:
# the set of `due` positions held by the deck's new cards is kept intact and
# reassigned so the lowest-ranked (most frequent) word gets the earliest slot.
# That keeps the reordering self-contained — it never shifts these cards past
# new cards in other decks. Cards whose Word isn't in JPDB sort last (they get
# the UNRANKED sentinel), tie-broken by their current position for stability.
#
# Only touches new cards (`is:new`); review/learning cards are never rescheduled.
module SortNewByWordFrequency
  UNRANKED = FrequencyDatabase::UNRANKED
end

cli = ScriptCLI.new(
  'sort-new-by-word-frequency.rb',
  "Reschedules the new (unseen) #{Kaishi::NOTE_TYPE_NAME} cards in a deck by word",
  'frequency, most common first, keeping their existing queue positions as a set.'
)
cli.dry_run('Preview the new order without rescheduling')
options = cli.parse!

db = cli.connect!

begin
  deck = options[:target_deck]
  query = %(note:"#{Kaishi::NOTE_TYPE_NAME}" deck:"#{deck}" is:new)
  cards = db.cards_info(query)

  ProgressReporter.success("Found #{cards.size} new #{Kaishi::NOTE_TYPE_NAME} cards in '#{deck}'")
  if cards.empty?
    puts 'Nothing to sort.'
    exit ScriptCLI::EXIT_OK
  end

  # Attach a frequency rank to each card (unknown words sort last).
  ranked = cards.map do |card|
    word = FrequencyDatabase.normalize_word(card[:fields][Kaishi::WORD_IDX])
    rank = (word.empty? ? nil : FrequencyDatabase.rank(word)) || SortNewByWordFrequency::UNRANKED
    card.merge(word: word, rank: rank)
  end

  # The queue positions to redistribute: exactly the ones these cards hold now,
  # smallest first. Reassigning within this set leaves other decks untouched.
  positions = ranked.map { |c| c[:due] }.sort

  # Sort by rank (most common first); tie-break on current position for a stable,
  # deterministic order. Then hand out the positions in that order.
  ordered = ranked.sort_by { |c| [c[:rank], c[:due]] }
  plan = ordered.each_with_index.map { |card, i| [card, positions[i]] }

  moves = plan.reject { |card, new_due| card[:due] == new_due }
  puts "Cards to reposition: #{moves.size} of #{plan.size}"
  puts ''

  stats = { total: plan.size, moved: 0, unranked: ranked.count { |c| c[:rank] == SortNewByWordFrequency::UNRANKED }, errors: 0 }

  puts options[:dry_run] ? 'Preview mode (no changes will be made):' : 'Rescheduling:'
  puts ''

  # Print the intended order top-to-bottom (most frequent first).
  db.transaction do
    ordered.each_with_index do |card, i|
      new_due = positions[i]
      rank_label = card[:rank] == SortNewByWordFrequency::UNRANKED ? 'unranked' : "freq #{card[:rank]}"
      word_label = card[:word].empty? ? '(blank)' : card[:word]
      line = format('%4d. %-12s %-12s pos %s→%s', i + 1, word_label, "(#{rank_label})", card[:due], new_due)

      if card[:due] == new_due
        puts "#{line} (in place)"
      elsif options[:dry_run]
        puts "#{line} [DRY RUN]"
      else
        begin
          db.set_card_due(card[:card_id], new_due)
          puts line
          stats[:moved] += 1
        rescue AnkiConnect::Error => e
          warn "#{line} ✗ #{e.message}"
          stats[:errors] += 1
        end
      end
    end
  end

  puts ''
  puts '=' * 70
  puts 'SUMMARY'
  puts '=' * 70
  puts "  New cards in deck:    #{stats[:total]}"
  puts "  Repositioned:         #{stats[:moved]}" unless options[:dry_run]
  puts "  Unranked (last):      #{stats[:unranked]}"
  puts "  Errors:               #{stats[:errors]}"
  puts '=' * 70
  puts ''

  if options[:dry_run]
    puts 'This was a dry run. No cards were rescheduled.'
    puts 'Run without --dry-run to apply.'
  elsif stats[:moved] > 0
    ProgressReporter.success("Rescheduled #{stats[:moved]} cards by frequency!")
  end

  exit(stats[:errors] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)
ensure
  db.close
end
