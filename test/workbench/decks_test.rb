# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require_relative '../../workbench/decks'
require_relative '../../workbench/preferences'
require_relative '../../workbench/steps'

class DecksTest < Minitest::Test
  def entry(name, needs_work)
    { 'name' => name, 'total' => 5, 'needs_work' => needs_work, 'counts' => {} }
  end

  def setup
    @calls = []
    @now = 0
    @status = lambda do |deck|
      @calls << deck
      decks = deck ? [entry(deck, 0)] : [entry('B', 2), entry('A', 1)]
      { 'checks' => [], 'decks' => decks, 'takoboto_decks' => [] }
    end
    @decks = Workbench::Decks.new(status: @status, deck_names: -> { %w[B A] }, clock: -> { @now })
  end

  def test_caches_the_whole_collection
    @decks.all
    @decks.all
    assert_equal [nil], @calls
    @now = 31
    @decks.all
    assert_equal [nil, nil], @calls
    @decks.all(refresh: true)
    assert_equal 3, @calls.size
    assert_equal %w[A B], @decks.all['deck_names']
  end

  def test_refresh_folds_one_deck_into_the_cache
    @decks.all
    @decks.refresh('B')
    assert_equal [nil, 'B'], @calls
    assert_equal [['A', 1], ['B', 0]], @decks.all['decks'].map { |d| [d['name'], d['needs_work']] }
  end
end

class PreferencesTest < Minitest::Test
  def test_remembers_only_marked_options_per_deck
    Dir.mktmpdir do |dir|
      prefs = Workbench::Preferences.new(File.join(dir, 'prefs.yaml'))
      step = Workbench::Steps.find('furigana')
      prefs.remember('幽霊', step, { 'provider' => 'opencode', 'model' => 'opencode/kimi-k2.6', 'limit' => '5' })
      prefs.remember('幽霊', step, { 'model' => '' })
      assert_equal({ '幽霊' => { 'furigana' => { 'provider' => 'opencode' } } }, prefs.all)
    end
  end
end
