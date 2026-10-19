# frozen_string_literal: true

require 'test_helper'
require 'furigana_reviewer'

class FuriganaReviewerTest < Minitest::Test
  # Answers every prompt with the given corrections.
  class FakeLLM
    def initialize(corrections)
      @corrections = corrections
    end

    def generate(_prompt)
      "---\n#{YAML.dump('corrections' => @corrections).sub(/\A---\n/, '')}"
    end
  end

  def review(corrections, furigana)
    reviewer = FuriganaReviewer.new(llm: FakeLLM.new(corrections))
    FuriganaReviewer.stub(:dictionary_notes, []) { reviewer.review([{ id: 1, sentence: '', furigana: furigana }]) }
  end

  def test_accepts_reading_changes
    result = review([{ 'id' => 1, 'furigana' => '後[あと]で' }], '後[のち]で')
    assert_equal({ 1 => '後[あと]で' }, result[:corrections])
    assert_empty result[:rejected]
  end

  def test_rejects_text_changes_and_returns_the_proposal
    proposed = '二人[ふたり]暮[ぐ]らしで'
    result = review([{ 'id' => 1, 'furigana' => proposed }], '二[に]人[にん]暮[くら]しで')
    assert_empty result[:corrections]
    assert_equal [[1, 'changed the sentence text, not just readings', proposed]], result[:rejected]
  end
end
