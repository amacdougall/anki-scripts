# frozen_string_literal: true

require 'test_helper'
require_relative '../../workbench/summary'

class SummaryTest < Minitest::Test
  Summary = Workbench::Summary

  KEYS = %w[stray_html sentence word_meaning sentence_meaning furigana furigana_review pitch_accent
            grammar_notes word_audio sentence_audio].freeze

  def deck(counts = {}, total: 100, name: '呪術廻戦')
    counts = KEYS.to_h { |k| [k, 0] }.merge(counts.transform_keys(&:to_s))
    needs_work = counts.values.max
    { 'name' => name, 'total' => total, 'needs_work' => needs_work, 'counts' => counts }
  end

  def summary(counts = {}, takoboto_decks = [])
    Summary.for(deck(counts), takoboto_decks: takoboto_decks, translation_notes: ['呪術廻戦'])
  end

  def test_complete_deck
    s = summary
    assert_nil s[:suggested]
    assert_equal({ text: 'Complete', kind: 'done' }, s[:badges]['furigana'])
    assert_equal({ text: 'Optional', kind: 'info' }, s[:badges]['sort'])
    assert_empty s[:dep_notes]
    assert_equal [['Every card in this deck is complete.', 'ok']], s[:advice].map { |a| [a[:text], a[:kind]] }
  end

  def test_suggested_is_the_first_fill_step_with_work
    assert_equal 'sentences', summary(sentence: 4, pitch_accent: 2)[:suggested]
    assert_equal 'furigana', summary(furigana_review: 3)[:suggested]
    assert_equal 'audio', summary(sentence_audio: 1)[:suggested]
  end

  def test_badges
    s = summary(word_audio: 3, sentence_audio: 4, furigana_review: 5)
    assert_equal({ text: '7 clips', kind: 'todo' }, s[:badges]['audio'])
    assert_equal({ text: '5 unreviewed', kind: 'todo' }, s[:badges]['furigana'])
    assert_equal({ text: '2 missing', kind: 'todo' }, summary(furigana: 2, furigana_review: 5)[:badges]['furigana'])
    assert_equal({ text: 'Info', kind: 'info' }, s[:badges]['mined'])
    assert_equal({ text: 'Empty', kind: 'info' }, s[:badges]['takoboto'])
    tako = summary({}, [{ 'name' => 'Takoboto A', 'count' => 3 }, { 'name' => 'Takoboto B', 'count' => 2 }])
    assert_equal({ text: '5 waiting', kind: 'todo' }, tako[:badges]['takoboto'])
  end

  def test_dep_notes_name_what_is_still_missing
    notes = summary(sentence: 41, stray_html: 1)[:dep_notes]
    assert_equal 'Strip HTML: 1 card still needs it. Run Furigana again after Strip HTML to pick it up. ' \
                 'Example sentences: 41 cards still need it. Run Furigana again after Example sentences to pick them up.',
                 notes['furigana']
    assert_includes notes['sentence_meanings'], 'Example sentences: 41'
    assert_includes notes['audio'], 'Example sentences: 41'
    assert_nil notes['meanings'], 'add-meanings needs nothing first'
  end

  def test_advice
    s = summary(stray_html: 2, sentence: 1, word_meaning: 3, sentence_meaning: 1, furigana: 1, word_audio: 1)
    texts = s[:advice].map { |a| a[:text] }
    assert_match(/\A2 cards have stray HTML/, texts[0])
    assert_match(/\A1 card has no example sentence/, texts[1])
    assert_match(/\A3 cards have no word meaning/, texts[2])
    assert_match(/before audio/, texts[3])
    assert_equal %w[strip_html sentences meanings furigana], s[:advice].map { |a| a[:step] }
  end

  def test_advice_for_missing_translation_notes
    s = Summary.for(deck({ sentence_meaning: 2 }, name: '幽霊'), translation_notes: ['呪術廻戦'])
    assert(s[:advice].any? { |a| a[:text].include?('prompts/translation/幽霊.md') })
    s = Summary.for(deck({ sentence_meaning: 2 }), translation_notes: ['呪術廻戦'])
    refute(s[:advice].any? { |a| a[:text].include?('prompts/translation') })
  end

  def test_advice_for_unreviewed_furigana_presets_the_review
    item = summary(furigana_review: 12)[:advice].find { |a| a[:step] == 'furigana' }
    assert_equal({ 'review_unreviewed' => true }, item[:preset])
  end

  def test_empty_deck
    s = Summary.for(nil, takoboto_decks: [{ 'name' => 'Takoboto A', 'count' => 3 }])
    assert_nil s[:suggested]
    assert_equal %w[takoboto word_list], s[:advice].map { |a| a[:step] }
  end
end
