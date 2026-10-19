# frozen_string_literal: true

require_relative 'kaishi_fields'
require_relative 'card_creator'
require_relative 'pitch_accent_renderer'
require_relative 'word_lookup'

# What "needs work" means for each part of a Kaishi card, in one place. Each
# script selects the notes it will process with these checks (plus --force),
# and deck-status.rb counts with the same checks, so a deck's "N missing" always
# matches what a run would touch.
#
# A note is the hash AnkiConnect returns: { id:, fields: [...], tags: [...] }.
module DeckStatus
  # Set once a note's sentence furigana has been through the AI review.
  # Regenerating the furigana clears it until the new furigana passes review.
  FURIGANA_REVIEWED_TAG = 'furigana::reviewed'

  # Pitch accent was generated; or Wadoku has no (unambiguous) entry for the
  # word, which is fine to leave as a gap. --force retries both.
  PITCH_ACCENT_TAG = 'generated::pitch-accent'
  PITCH_ACCENT_UNAVAILABLE_TAG = 'pitch-accent::unavailable'
  # Pre-tag marker in the Pitch Accent field, still recognized.
  PITCH_ACCENT_MARKER = PitchAccentRenderer::GENERATED_MARKER

  # JMdict grammar notes were added (or JMdict had none for the word).
  GRAMMAR_TAG = 'generated::grammar'
  # Pre-tag markers in the Notes field, still recognized.
  GRAMMAR_MARKERS = ['<!-- jmdict-grammar -->', '<!-- jisho-grammar -->'].freeze

  # A clip generate-gemini-audio.rb has committed to (re)generating. Notes still
  # tagged after an interrupted run are picked up by the next one.
  AUDIO_PENDING_TAGS = {
    'word' => 'audio::pending::word',
    'sent' => 'audio::pending::sentence'
  }.freeze

  # HTML other than the <ruby>/<rt>/<rp> tags furigana uses.
  STRAY_HTML = %r{<(?!/?(?:ruby|rt|rp)\b)[^>]+>}
  STRAY_HTML_FIELDS = [Kaishi::WORD_IDX, Kaishi::WORD_FURIGANA_IDX,
                       Kaishi::SENTENCE_IDX, Kaishi::SENTENCE_FURIGANA_IDX].freeze

  KANJI = /[一-鿿㐀-䶿]/

  Check = Struct.new(:key, :label, :script, keyword_init: true)

  # In the suggested workflow order.
  CHECKS = [
    Check.new(key: :stray_html, label: 'Stray HTML', script: 'strip-word-html.rb'),
    Check.new(key: :sentence, label: 'Example sentence', script: 'generate-sentences.rb'),
    Check.new(key: :word_meaning, label: 'Word meaning', script: 'add-meanings.rb'),
    Check.new(key: :sentence_meaning, label: 'Sentence meaning', script: 'add-sentence-meanings.rb'),
    Check.new(key: :furigana, label: 'Furigana', script: 'generate-furigana.rb'),
    Check.new(key: :furigana_review, label: 'Furigana review', script: 'generate-furigana.rb'),
    Check.new(key: :pitch_accent, label: 'Pitch accent', script: 'generate-pitch-accent.rb'),
    Check.new(key: :grammar_notes, label: 'Grammar notes', script: 'add-jmdict-grammar-notes.rb'),
    Check.new(key: :word_audio, label: 'Word audio', script: 'generate-gemini-audio.rb'),
    Check.new(key: :sentence_audio, label: 'Sentence audio', script: 'generate-gemini-audio.rb')
  ].freeze

  module_function

  def needs?(key, note)
    public_send("needs_#{key}?", note)
  end

  # { total: N, stray_html: n, sentence: n, ... } for a list of notes.
  def counts(notes)
    CHECKS.to_h { |check| [check.key, notes.count { |note| needs?(check.key, note) }] }
          .merge(total: notes.size)
  end

  # --- The checks ---

  def needs_stray_html?(note)
    STRAY_HTML_FIELDS.any? { |idx| field(note, idx).match?(STRAY_HTML) }
  end

  def needs_sentence?(note)
    present?(field(note, Kaishi::WORD_IDX)) && blank?(field(note, Kaishi::SENTENCE_IDX))
  end

  def needs_word_meaning?(note)
    present?(field(note, Kaishi::WORD_IDX)) && blank?(field(note, Kaishi::WORD_MEANING_IDX))
  end

  def needs_sentence_meaning?(note)
    present?(field(note, Kaishi::SENTENCE_IDX)) && blank?(field(note, Kaishi::SENTENCE_MEANING_IDX))
  end

  # Word or sentence furigana is missing, or the word is one JMdict marks
  # "usually written in kana" whose Word field still needs its <ruby> form.
  def needs_furigana?(note)
    word = field(note, Kaishi::WORD_IDX)
    word_furigana = field(note, Kaishi::WORD_FURIGANA_IDX)
    sentence = field(note, Kaishi::SENTENCE_IDX)
    sentence_furigana = field(note, Kaishi::SENTENCE_FURIGANA_IDX)

    (!word_furigana.include?('[') && kanji?(word)) ||
      (blank?(word_furigana) && present?(word)) ||
      (!sentence_furigana.include?('[') && kanji?(sentence)) ||
      needs_word_ruby?(note)
  end

  def needs_word_ruby?(note)
    word = field(note, Kaishi::WORD_IDX)
    return false unless kanji?(word) && !word.include?('<ruby>')

    entry = WordLookup.entry_for(CardCreator.strip_ruby_tags(word), field(note, Kaishi::WORD_READING_IDX).strip)
    WordLookup.usually_kana?(entry)
  end

  def needs_furigana_review?(note)
    field(note, Kaishi::SENTENCE_FURIGANA_IDX).include?('[') && !tagged?(note, FURIGANA_REVIEWED_TAG)
  end

  def needs_pitch_accent?(note)
    present?(field(note, Kaishi::WORD_IDX)) &&
      !tagged?(note, PITCH_ACCENT_TAG) && !tagged?(note, PITCH_ACCENT_UNAVAILABLE_TAG) &&
      !field(note, Kaishi::PITCH_ACCENT_IDX).include?(PITCH_ACCENT_MARKER)
  end

  def needs_grammar_notes?(note)
    notes_field = field(note, Kaishi::NOTES_IDX)
    present?(field(note, Kaishi::WORD_IDX)) &&
      !tagged?(note, GRAMMAR_TAG) && GRAMMAR_MARKERS.none? { |marker| notes_field.include?(marker) }
  end

  def needs_word_audio?(note)
    present?(field(note, Kaishi::WORD_IDX)) &&
      (blank?(field(note, Kaishi::WORD_AUDIO_IDX)) || tagged?(note, AUDIO_PENDING_TAGS['word']))
  end

  def needs_sentence_audio?(note)
    present?(field(note, Kaishi::SENTENCE_IDX)) &&
      (blank?(field(note, Kaishi::SENTENCE_AUDIO_IDX)) || tagged?(note, AUDIO_PENDING_TAGS['sent']))
  end

  # --- Helpers ---

  def strip_stray_html(text)
    text.gsub(STRAY_HTML, '')
  end

  def kanji?(text)
    text.match?(KANJI)
  end

  def field(note, idx)
    note[:fields][idx].to_s
  end

  def tagged?(note, tag)
    (note[:tags] || []).include?(tag)
  end

  def present?(text)
    !blank?(text)
  end

  def blank?(text)
    text.strip.empty?
  end
end
