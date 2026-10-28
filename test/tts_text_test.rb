# frozen_string_literal: true

require 'test_helper'
require 'tts_text'
require 'gemini_tts'

class TtsTextTest < Minitest::Test
  def segments(text) = TtsText.language_segments(text)

  def test_english_quote_in_japanese_sentence
    assert_equal [[:en, "Relax. It's just twenty minutes"], [:ja, '」エバンは平然とした口調で言った。']],
                 segments("「Relax. It's just twenty minutes」エバンは平然とした口調で言った。")
  end

  def test_english_in_the_middle
    assert_equal [[:ja, '彼は「'], [:en, 'I love you'], [:ja, '」と言った。']],
                 segments('彼は「I love you」と言った。')
  end

  def test_single_english_words_stay_japanese
    assert_equal [[:ja, 'OKです。Tシャツを着る。全部English']], segments('OKです。Tシャツを着る。全部English')
  end

  def test_numbers_join_a_run_but_do_not_count_as_words
    assert_equal [[:en, "It's 20 minutes"], [:ja, '、だって']], segments("It's 20 minutes、だって")
    assert_equal [[:ja, 'ABC 123 です']], segments('ABC 123 です')
  end

  def test_names_titles_and_loanword_phrases_stay_japanese
    ['「Black Box」のボーカリスト', 'Prince Paulのプロデュース論', '『The Baby-Sitters Club』の原書',
     'weekly sync ミーティング', 'これはteam Bと連携します', 'Verb/adjectives/noun Conjugation review sheetを作った'].each do |text|
      assert_equal [[:ja, text]], segments(text), text
    end
  end

  def test_grammar_words_mark_speech
    assert_equal [[:en, "i'm sorry"], [:ja, 'あっかんべ']], segments("i'm sorry あっかんべ")
    assert_equal [[:ja, '原文が『'], [:en, 'The sky is blue'], [:ja, '』でも']], segments('原文が『The sky is blue』でも')
    assert_equal [[:en, "Don’t worry"], [:ja, 'と彼は言った']], segments('Don’t worryと彼は言った')
  end

  def test_plain_japanese_is_one_segment
    assert_equal [[:ja, '街並みが綺麗だ。']], segments('街並みが綺麗だ。')
  end

  def test_result_join
    a = GeminiTTS::Result.new(pcm: "\x01\x00".b, finish_reason: 'STOP', model: 'gemini-3.8-flash-lite-tts',
                              usage: { 'promptTokenCount' => 10, 'candidatesTokenCount' => 100 })
    b = GeminiTTS::Result.new(pcm: "\x02\x00".b, finish_reason: 'OTHER', model: 'gemini-3.8-flash-lite-tts',
                              usage: { 'promptTokenCount' => 5, 'candidatesTokenCount' => 50 })
    joined = GeminiTTS::Result.join([a, b])

    assert_equal "\x01\x00\x02\x00".b, joined.pcm
    assert_equal 'OTHER', joined.finish_reason
    assert_in_delta a.cost + b.cost, joined.cost
  end
end
