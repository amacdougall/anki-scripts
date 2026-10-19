# frozen_string_literal: true

require 'yaml'

# LLM providers, models and per-task defaults, read from config/llm-models.yaml
# so a retired model only has to be replaced there. Each script's --model flag
# overrides the default for a single run.
module LlmConfig
  PATH = File.expand_path('../config/llm-models.yaml', __dir__)

  # The tasks scripts ask for, as named in the config's tasks: section.
  TASKS = %i[word_meaning sentence_translation furigana_review sentence_generation].freeze

  class Error < StandardError; end

  def self.data
    @data ||= YAML.safe_load_file(PATH)
  end

  # Replaces the loaded config (tests use this); nil reloads from PATH.
  def self.data=(data)
    @data = data
  end

  def self.default_provider
    data.fetch('default_provider')
  end

  # Provider names, e.g. ["claude", "opencode"].
  def self.providers
    data.fetch('providers').keys
  end

  # Models listed for a provider; [] for one the config doesn't list.
  def self.models(provider)
    data.dig('providers', provider.to_s, 'models') || []
  end

  # The model a task uses with a provider unless --model says otherwise.
  def self.default_model(task, provider)
    model = data.dig('tasks', task.to_s, provider.to_s)
    raise Error, "#{PATH}: no #{provider} model for task #{task}" unless model

    model
  end
end
