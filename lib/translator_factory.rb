# frozen_string_literal: true

require_relative 'google_translation_provider'
require_relative 'llm_translation_provider'
require_relative 'claude_interface'
require_relative 'opencode_interface'
require_relative 'text_transforms'
require_relative 'llm_defaults'

# Builds a translation provider (see GoogleTranslationProvider and
# LlmTranslationProvider) from a --provider/--model CLI pair. Shared by every
# script that needs a Japanese->English fallback: add-sentence-meanings.rb,
# add-cards.rb, and add-meanings.rb (via WordLookup).
module TranslatorFactory
  class UnknownProviderError < StandardError; end

  # deck_name, when given, looks up that deck's TextTransforms entry (if any)
  # and passes it to LlmTranslationProvider so it can hint the LLM about
  # non-standard readings (e.g. character names). Ignored for 'google', which
  # has no such hinting mechanism. Most decks have no entry, in which case
  # translation proceeds exactly as before.
  def self.build(provider, model = nil, deck_name: nil, verbose: true)
    case provider
    when 'google'
      GoogleTranslationProvider.new(verbose: verbose)
    when 'claude'
      LlmTranslationProvider.new(llm: ClaudeInterface.new(model: model || LlmDefaults::TRANSLATION['claude']), transforms: transforms_for(deck_name), deck_name: deck_name)
    when 'opencode'
      LlmTranslationProvider.new(llm: OpenCodeInterface.new(model: model || LlmDefaults::TRANSLATION['opencode']), transforms: transforms_for(deck_name), deck_name: deck_name)
    else
      raise UnknownProviderError, "Unknown provider: #{provider}. Use 'google', 'claude', or 'opencode'."
    end
  end

  # Just the LLM CLI interface for 'claude' or 'opencode', for callers that
  # prompt the model directly (e.g. FuriganaReviewer) rather than translating.
  # defaults is one of the LlmDefaults per-task hashes.
  def self.llm(provider, model = nil, defaults: LlmDefaults::TRANSLATION)
    case provider
    when 'claude'   then ClaudeInterface.new(model: model || defaults['claude'])
    when 'opencode' then OpenCodeInterface.new(model: model || defaults['opencode'])
    else raise UnknownProviderError, "Unknown LLM provider: #{provider}. Use 'claude' or 'opencode'."
    end
  end

  def self.transforms_for(deck_name)
    return nil unless deck_name

    TextTransforms::DECK_TEXT_TRANSFORMS[deck_name]
  end
  private_class_method :transforms_for
end
