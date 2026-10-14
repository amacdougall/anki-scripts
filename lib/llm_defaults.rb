# frozen_string_literal: true

# Default LLM models for every script, per task and provider, so a retired
# model only has to be replaced here. Each script's --model flag overrides
# these for a single run.
module LlmDefaults
  # The OpenCode model all tasks use. OpenCode can drop a model from its
  # servers while `opencode models` still lists it (deepseek-v4-flash started
  # returning 404 in October 2026), so check that first if every request fails.
  OPENCODE_MODEL = 'opencode/deepseek-v4.1-flash'

  # Translating short words and sentences: a small, fast model is plenty, so
  # Haiku rather than Sonnet.
  TRANSLATION = {
    'claude' => 'haiku',
    'opencode' => OPENCODE_MODEL
  }.freeze

  # Reviewing sentence furigana (generate-furigana.rb).
  FURIGANA_REVIEW = {
    'claude' => 'haiku',
    'opencode' => OPENCODE_MODEL
  }.freeze

  # Writing example sentences (generate-sentences.rb).
  SENTENCE_GENERATION = {
    'claude' => 'sonnet',
    'opencode' => OPENCODE_MODEL
  }.freeze
end
