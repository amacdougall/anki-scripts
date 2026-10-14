# frozen_string_literal: true

require 'yaml'

# Deck-specific text substitutions for terms (typically character names) whose
# kanji have non-standard readings. Entries map a kanji string to its
# bracket-notation furigana, e.g. '水月' => '水月[みずき]'.
#
# The table is loaded from config/deck-readings.yaml (gitignored; copy
# config/deck-readings.example.yaml to start), which maps each deck name to
# { kanji => kana reading }. Without that file, no deck has transforms.
#
# Two consumption paths:
#
#   apply_reading  — substitute the kanji with its kana reading. Used by the
#                    TTS pipeline so the voice speaks the intended reading.
#
#   apply_furigana — substitute the kanji with a Private-Use-Area placeholder
#                    that MeCab passes through as an unknown token, and return
#                    a restore lambda that re-injects the bracket form into
#                    MeCab's output.
module TextTransforms
  CONFIG_PATH = File.expand_path('../config/deck-readings.yaml', __dir__)

  # { deck name => { kanji => 'kanji[reading]' } }, built from CONFIG_PATH.
  def self.load_config(path = CONFIG_PATH)
    return {} unless File.exist?(path)

    data = YAML.safe_load_file(path) || {}
    raise "#{path}: expected a mapping of deck names to { kanji: reading }" unless data.is_a?(Hash)

    data.to_h do |deck, readings|
      raise "#{path}: deck #{deck.inspect} must map kanji to readings" unless readings.is_a?(Hash)

      [deck.to_s, readings.to_h { |kanji, reading| [kanji.to_s, "#{kanji}[#{reading}]"] }.freeze]
    end.freeze
  end

  DECK_TEXT_TRANSFORMS = load_config

  # Base of the Unicode Private Use Area. Codepoints starting here are used as
  # opaque placeholders MeCab will not try to assign readings to.
  PLACEHOLDER_BASE = 0xE000

  # Replace each transform key with its kana reading.
  def self.apply_reading(text, deck_name)
    transforms = DECK_TEXT_TRANSFORMS[deck_name]
    return text unless transforms

    transforms.reduce(text) do |t, (from, to)|
      t.gsub(from, extract_reading(to))
    end
  end

  # Replace each transform key with a unique placeholder character. Returns
  # [transformed_text, restore], where restore takes MeCab's bracket-notation
  # output and substitutes each placeholder back with its bracket form,
  # fixing up spacing so the result follows Anki furigana conventions.
  def self.apply_furigana(text, deck_name)
    transforms = DECK_TEXT_TRANSFORMS[deck_name]
    return [text, ->(out) { out }] unless transforms

    apply_furigana_transforms(text, transforms)
  end

  # Same placeholder/restore mechanism as apply_furigana, but driven by an
  # explicit { kanji => 'kanji[reading]' } hash rather than the per-deck table.
  # Used when the caller knows the exact readings to inject, so MeCab never has
  # to guess them.
  def self.apply_furigana_transforms(text, transforms)
    return [text, ->(out) { out }] if transforms.nil? || transforms.empty?

    placeholders = {}
    transformed = text.dup
    transforms.each_with_index do |(from, to), idx|
      next unless transformed.include?(from)
      placeholder = (PLACEHOLDER_BASE + idx).chr(Encoding::UTF_8)
      transformed = transformed.gsub(from, placeholder)
      placeholders[placeholder] = to
    end

    # MeCab's format_nodes only inserts a space before a bracket-form token when
    # the previous char isn't ']'. Placeholders are emitted as bare tokens (no
    # reading), so any kana directly preceding one ends up flush against the
    # bracket form once we substitute it back. Reinsert the missing space at
    # each substitution site — but only there, so we don't disturb the spacing
    # MeCab already produced for the rest of the output.
    restore = lambda do |out|
      placeholders.reduce(out) do |r, (placeholder, bracket)|
        r.gsub(/(.?)#{Regexp.escape(placeholder)}/) do
          prev = Regexp.last_match(1)
          needs_space = !prev.empty? && prev != ']' && !prev.match?(/\s/)
          "#{prev}#{needs_space ? ' ' : ''}#{bracket}"
        end
      end
    end

    [transformed, restore]
  end

  # Extract the kana inside the bracket form, e.g. '水月[みずき]' => 'みずき'.
  # Public so callers (e.g. LlmTranslationProvider) can build reading hints
  # from a raw DECK_TEXT_TRANSFORMS entry.
  def self.extract_reading(bracket_form)
    bracket_form[/\[([^\]]+)\]/, 1] || bracket_form
  end
end
