# frozen_string_literal: true

# Shared helpers for creating Anki vocabulary cards using the Kaishi 1.5k note type.
#
# Note creation itself now goes through AnkiConnect#add_note(s); this module only
# holds the pure field-shaping helpers (no database access).

require_relative 'kaishi_fields'

module CardCreator
  NOTE_TYPE_NAME = Kaishi::NOTE_TYPE_NAME

  # Convert bracket-notation furigana (e.g. "食[た]べる") to <ruby> tags.
  # Anki's "word" field doesn't render bracket notation, so we use ruby tags
  # for inline display.
  def self.bracket_to_ruby(text)
    text.gsub(/ ?([^\s\[\]]+)\[([^\]]+)\]/, '<ruby>\1<rt>\2</rt></ruby>')
  end

  # Inverse of bracket_to_ruby — strips ruby tags so a word can be compared
  # against existing plain-kanji entries for deduplication.
  def self.strip_ruby_tags(text)
    text.gsub(/<rt>[^<]*<\/rt>/, '').gsub(/<\/?ruby>/, '')
  end

  # Build the 14-field array for a Kaishi 1.5k note.
  def self.build_fields(word:, reading: '', meaning: '', sentence: '', sentence_meaning: '', note: '')
    fields = Array.new(Kaishi::EXPECTED_FIELD_COUNT, '')
    fields[Kaishi::WORD_IDX]             = word
    fields[Kaishi::WORD_READING_IDX]     = reading
    fields[Kaishi::WORD_MEANING_IDX]     = meaning
    fields[Kaishi::SENTENCE_IDX]         = sentence
    fields[Kaishi::SENTENCE_MEANING_IDX] = sentence_meaning
    fields[Kaishi::NOTES_IDX]            = note
    fields
  end
end
