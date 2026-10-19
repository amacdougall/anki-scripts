# frozen_string_literal: true

require_relative 'google_translation_provider'
require_relative 'llm_translation_provider'
require_relative 'claude_interface'
require_relative 'opencode_interface'
require_relative 'text_transforms'
require_relative 'llm_config'

# Builds a translation provider (see GoogleTranslationProvider and
# LlmTranslationProvider) from a --provider/--model CLI pair. Shared by every
# script that needs a Japanese->English fallback: add-sentence-meanings.rb,
# add-cards.rb, and add-meanings.rb (via WordLookup).
module TranslatorFactory
  class UnknownProviderError < StandardError; end

  # task picks the default model from config/llm-models.yaml when model is nil.
  #
  # deck_name, when given, looks up that deck's TextTransforms entry (if any)
  # and passes it to LlmTranslationProvider so it can hint the LLM about
  # non-standard readings (e.g. character names). Ignored for 'google', which
  # has no such hinting mechanism. Most decks have no entry, in which case
  # translation proceeds exactly as before.
  def self.build(provider, model = nil, task: :sentence_translation, deck_name: nil, verbose: true)
    return GoogleTranslationProvider.new(verbose: verbose) if provider == 'google'

    LlmTranslationProvider.new(llm: llm(provider, model, task: task),
                               transforms: transforms_for(deck_name), deck_name: deck_name)
  end

  # Just the LLM CLI interface for 'claude' or 'opencode', for callers that
  # prompt the model directly (e.g. FuriganaReviewer) rather than translating.
  def self.llm(provider, model = nil, task: :sentence_translation, verbose: false)
    model ||= LlmConfig.default_model(task, provider) if %w[claude opencode].include?(provider)
    case provider
    when 'claude'   then ClaudeInterface.new(model: model, verbose: verbose)
    when 'opencode' then OpenCodeInterface.new(model: model, verbose: verbose)
    else raise UnknownProviderError, "Unknown LLM provider: #{provider}. Use 'claude' or 'opencode'."
    end
  end

  def self.transforms_for(deck_name)
    return nil unless deck_name

    TextTransforms::DECK_TEXT_TRANSFORMS[deck_name]
  end
  private_class_method :transforms_for
end
