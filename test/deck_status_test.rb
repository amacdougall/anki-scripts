# frozen_string_literal: true

require 'test_helper'
require 'deck_status'

class DeckStatusTest < Minitest::Test
  include TestHelpers

  W = Kaishi::WORD_IDX
  WR = Kaishi::WORD_READING_IDX
  WM = Kaishi::WORD_MEANING_IDX
  WF = Kaishi::WORD_FURIGANA_IDX
  WA = Kaishi::WORD_AUDIO_IDX
  S = Kaishi::SENTENCE_IDX
  SM = Kaishi::SENTENCE_MEANING_IDX
  SF = Kaishi::SENTENCE_FURIGANA_IDX
  SA = Kaishi::SENTENCE_AUDIO_IDX
  N = Kaishi::NOTES_IDX
  PA = Kaishi::PITCH_ACCENT_IDX

  # A note with every field filled in and every "done" tag, so each test can
  # knock out the one part it cares about.
  def complete_note(overrides = {})
    overrides = overrides.dup
    tags = overrides.delete(:tags)
    note({ W => '学校', WR => 'がっこう', WM => 'school', WF => '学校[がっこう]', WA => '[sound:w.wav]',
           S => '学校に行く。', SM => 'I go to school.', SF => '学校[がっこう]に 行[い]く。',
           SA => '[sound:s.wav]', N => 'n.', PA => '<span>pitch</span>' }.merge(overrides),
         tags: tags || [DeckStatus::FURIGANA_REVIEWED_TAG, DeckStatus::PITCH_ACCENT_TAG, DeckStatus::GRAMMAR_TAG])
  end

  def needs?(key, note)
    WordLookup.stub(:entry_for, nil) { DeckStatus.needs?(key, note) }
  end

  def test_complete_note_needs_nothing
    DeckStatus::CHECKS.each do |check|
      refute needs?(check.key, complete_note), "#{check.key} should be done"
    end
  end

  def test_stray_html_ignores_ruby_tags
    refute needs?(:stray_html, complete_note(W => '<ruby>食<rt>た</rt></ruby>べる'))
    assert needs?(:stray_html, complete_note(S => '<b>学校</b>に行く。'))
    assert_equal '学校に<ruby>行<rt>い</rt></ruby>く。',
                 DeckStatus.strip_stray_html('<b>学校</b>に<br><ruby>行<rt>い</rt></ruby>く。')
  end

  def test_meanings_need_their_source_text
    assert needs?(:word_meaning, complete_note(WM => ' '))
    assert needs?(:sentence_meaning, complete_note(SM => ''))
    refute needs?(:sentence_meaning, complete_note(S => '', SM => '')), 'no sentence to translate yet'
  end

  def test_sentence
    assert needs?(:sentence, complete_note(S => ''))
    refute needs?(:sentence, complete_note(W => '', S => ''))
  end

  def test_furigana
    assert needs?(:furigana, complete_note(WF => '')), 'empty word furigana'
    assert needs?(:furigana, complete_note(SF => '学校に行く。')), 'sentence furigana without readings'
    refute needs?(:furigana, complete_note(S => 'いく。', SF => 'いく。')), 'kana-only sentence'
  end

  def test_furigana_needs_ruby_for_usually_kana_words
    with_uk = complete_note(W => '流石', WF => '流石[さすが]')
    WordLookup.stub(:entry_for, :entry) do
      WordLookup.stub(:usually_kana?, true) do
        assert DeckStatus.needs?(:furigana, with_uk)
      end
    end
  end

  def test_furigana_review
    assert needs?(:furigana_review, complete_note(tags: []))
    refute needs?(:furigana_review, complete_note(SF => '', tags: [])), 'nothing to review'
  end

  def test_pitch_accent_gaps_are_done
    assert needs?(:pitch_accent, complete_note(tags: []))
    refute needs?(:pitch_accent, complete_note(tags: [DeckStatus::PITCH_ACCENT_UNAVAILABLE_TAG]))
    refute needs?(:pitch_accent, complete_note(PA => "x#{DeckStatus::PITCH_ACCENT_MARKER}", tags: []))
  end

  def test_grammar_notes_legacy_markers
    assert needs?(:grammar_notes, complete_note(tags: []))
    refute needs?(:grammar_notes, complete_note(N => 'vt. <!-- jisho-grammar -->', tags: []))
  end

  def test_audio_missing_or_pending
    assert needs?(:word_audio, complete_note(WA => ''))
    assert needs?(:sentence_audio, complete_note(tags: [DeckStatus::AUDIO_PENDING_TAGS['sent']]))
    refute needs?(:sentence_audio, complete_note(S => '', SA => ''))
  end

  def test_counts
    notes = [complete_note, complete_note(WA => '', SM => ''), complete_note(WA => '')]
    counts = WordLookup.stub(:entry_for, nil) { DeckStatus.counts(notes) }
    assert_equal 3, counts[:total]
    assert_equal 2, counts[:word_audio]
    assert_equal 1, counts[:sentence_meaning]
    assert_equal 0, counts[:sentence]
  end
end
