# frozen_string_literal: true

require 'test_helper'
require 'deck_stats'

class DeckStatsTest < Minitest::Test
  # Answers card searches from a fixed table of query suffix => ids.
  class FakeDb
    def initialize(ids, by_query, decks)
      @ids = ids
      @by_query = by_query
      @decks = decks
    end

    def find_card_ids(query)
      suffix = query.sub(/\Anote:"[^"]*" ?/, '')
      suffix.empty? ? @ids : @by_query.fetch(suffix, [])
    end

    def decks_for_cards(_ids) = @decks
  end

  def test_each_card_lands_in_one_state
    db = FakeDb.new(
      [1, 2, 3, 4, 5, 6],
      { 'is:suspended' => [6], 'is:new' => [1, 6], 'is:learn' => [2], 'prop:ivl>=21' => [2, 4] },
      { '毎日' => [1, 2, 3], '呪術廻戦' => [4, 5, 6] }
    )
    decks = DeckStats.by_deck(db)

    assert_equal %w[呪術廻戦 毎日], decks.map { |d| d[:name] }
    assert_equal({ name: '毎日', total: 3, new: 1, learning: 1, young: 1, mature: 0, suspended: 0 }, decks[1])
    assert_equal({ name: '呪術廻戦', total: 3, new: 0, learning: 0, young: 1, mature: 1, suspended: 1 }, decks[0])
    assert_equal({ total: 6, new: 1, learning: 1, young: 2, mature: 1, suspended: 1 }, DeckStats.totals(decks))
  end

  def test_no_cards
    assert_empty DeckStats.by_deck(FakeDb.new([], {}, {}))
  end
end
