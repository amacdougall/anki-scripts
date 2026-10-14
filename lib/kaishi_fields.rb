# frozen_string_literal: true

# Field layout for the Kaishi 1.5k note type.
#
# This is the Japanese-learning-specific knowledge for this project's note type.
# Keeping it separate from the Anki access layer (AnkiConnect) lets that layer
# stay general-purpose, while the indices and field count below describe this
# particular note type.
module Kaishi
  NOTE_TYPE_NAME = 'Kaishi 1.5k'

  # Number of fields in the Kaishi 1.5k note type. Used when building a fresh
  # field array from scratch. (AnkiConnect maps array indices to field names by
  # the note type's field order at write time, so writes don't need this.)
  EXPECTED_FIELD_COUNT = 14

  # Verified field indices for the Kaishi 1.5k note type.
  WORD_IDX = 0
  WORD_READING_IDX = 1
  WORD_MEANING_IDX = 2
  WORD_FURIGANA_IDX = 3
  SENTENCE_IDX = 5
  SENTENCE_MEANING_IDX = 6
  SENTENCE_FURIGANA_IDX = 7
  NOTES_IDX = 9
  FREQUENCY_IDX = 12
end
