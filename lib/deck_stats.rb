# frozen_string_literal: true

require_relative 'kaishi_fields'

# Anki's own card counts for the Kaishi cards in each deck: new, learning,
# young, mature and suspended, as Anki's Statistics screen splits them (mature
# means an interval of 21 days or more). Each card falls in exactly one bucket;
# a suspended card counts as suspended whatever state it was in.
#
# Built from a handful of card searches plus one getDecks call, so it's quick
# even for the whole collection. Read-only.
module DeckStats
  STATES = %i[new learning young mature suspended].freeze

  # Searches for every state but young, which is whatever is left. Checked in
  # this order, so a suspended learning card is suspended, a relearning card
  # with a long interval is learning, and so on.
  QUERIES = {
    suspended: 'is:suspended',
    new: 'is:new',
    learning: 'is:learn',
    mature: 'prop:ivl>=21'
  }.freeze

  module_function

  # [{ name:, total:, new:, learning:, young:, mature:, suspended: }] sorted by
  # deck name, for the decks holding Kaishi cards (the curated deck included).
  # db: an AnkiConnect.
  def by_deck(db)
    base = %(note:"#{Kaishi::NOTE_TYPE_NAME}")
    ids = db.find_card_ids(base)
    return [] if ids.empty?

    sets = QUERIES.transform_values { |query| db.find_card_ids("#{base} #{query}").to_set }
    db.decks_for_cards(ids).sort.map do |name, deck_ids|
      counts = STATES.to_h { |s| [s, 0] }
      deck_ids.each { |id| counts[state(id, sets)] += 1 }
      { name: name, total: deck_ids.size, **counts }
    end
  end

  # The decks' counts added up.
  def totals(decks)
    (%i[total] + STATES).to_h { |key| [key, decks.sum { |d| d[key] }] }
  end

  def state(id, sets)
    QUERIES.each_key { |key| return key if sets[key].include?(id) }
    :young
  end
end
