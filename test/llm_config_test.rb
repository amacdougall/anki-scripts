# frozen_string_literal: true

require 'test_helper'
require 'llm_config'

class LlmConfigTest < Minitest::Test
  # The committed config must cover every task for every provider.
  def test_config_covers_every_task
    LlmConfig::TASKS.each do |task|
      LlmConfig.providers.each do |provider|
        model = LlmConfig.default_model(task, provider)
        assert_includes LlmConfig.models(provider), model, "#{task}/#{provider} default isn't a listed model"
      end
    end
  end

  def test_default_provider_is_listed
    assert_includes LlmConfig.providers, LlmConfig.default_provider
  end

  def test_unknown_task_raises
    assert_raises(LlmConfig::Error) { LlmConfig.default_model(:nonsense, 'claude') }
  end

  def test_unlisted_provider_has_no_models
    assert_equal [], LlmConfig.models('google')
  end
end
