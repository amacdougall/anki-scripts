# frozen_string_literal: true

require 'set'
require_relative 'card_creator'
require_relative 'kaishi_fields'

# Shared duplicate-detection for Kaishi 1.5k vocabulary cards.
#
# Checks against every deck that uses the Kaishi 1.5k note type, not just
# whichever deck a card is being added to — the same word can legitimately
# live in a staging deck (e.g. a per-book deck) and the "real" deck (Kaishi 1.5k)
# at once, and we never want it in both. Dedup is strictly (word, reading):
# distinct readings of the same kanji (e.g. 主 as ぬし vs. しゅ) are treated
# as different vocabulary and both get cards.
class DedupChecker
  # Builds the existing-card key set from Anki. `db` is a connected
  # AnkiConnect instance. Pass `nil` deck (the default, via AnkiConnect's own
  # default) to scan every deck using this note type.
  def initialize(db, note_type: Kaishi::NOTE_TYPE_NAME)
    @keys = Set.new(
      db.notes_in_deck(nil, note_type: note_type).map { |note| key_for(note[:fields]) }
    )
  end

  # True if a card with this (word, reading) pair already exists anywhere.
  def duplicate?(word, reading)
    @keys.include?(normalize(word, reading))
  end

  # Record a newly-created card so later entries in the same run are also
  # recognized as duplicates.
  def add(word, reading)
    @keys << normalize(word, reading)
  end

  private

  def key_for(fields)
    [CardCreator.strip_ruby_tags(fields[Kaishi::WORD_IDX] || ''), fields[Kaishi::WORD_READING_IDX] || '']
  end

  def normalize(word, reading)
    [CardCreator.strip_ruby_tags(word || ''), reading || '']
  end
end
