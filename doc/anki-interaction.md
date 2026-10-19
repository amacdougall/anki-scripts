# Anki Interaction Reference

This document describes how the project interacts with Anki. All access goes
through the **AnkiConnect** add-on, which exposes a JSON-RPC HTTP API while Anki
is running. Anki itself performs every read and write.

## Overview

- **Add-on:** [AnkiConnect](https://git.sr.ht/~foosoft/anki-connect), listening
  on `http://127.0.0.1:8765`.
- **API key (optional):** if `apiKey` is set in the add-on config, export the
  same value as `$ANKICONNECT_API_KEY`; it's sent as `key` on every request.
  Pass `AnkiConnect.new(api_key: ...)` to override.
- **Primary note type:** Kaishi 1.5k (14 fields).
- **Requirement:** Anki must be **running** with the
  AnkiConnect add-on installed. Scripts call `AnkiConnect.require_running!`,
  which pings the server and exits with a clear message if it can't reach it.

All access goes through the `AnkiConnect` class (`lib/anki_connect.rb`). The
Kaishi-specific field layout lives in the `Kaishi` module
(`lib/kaishi_fields.rb`). `AnkiConnect` is general-purpose and knows nothing
about Kaishi or Japanese, so it can be copied into other Anki projects unchanged.

## AnkiConnect Class API

### Connection and safety

```ruby
AnkiConnect.require_running!     # class method: exits 1 if Anki/AnkiConnect is unreachable
db = AnkiConnect.new.connect     # verifies the server, returns self
db.close                         # no-op (no persistent connection); kept for symmetry
db.sync                          # trigger an AnkiWeb sync
```

There are **no** backups, "close Anki" checks, or `usn`/`mod` bookkeeping —
Anki owns the write and tracks sync state itself.

### Decks and note types

```ruby
db.find_deck_id('日本語の言葉')   # returns the deck NAME if it exists, else nil
db.deck_names                     # array of all deck names
db.find_note_type_id('Kaishi 1.5k') # returns the note type NAME if it exists, else nil
db.field_names('Kaishi 1.5k')     # ordered field names (cached); used internally for writes
```

> Deck/note-type "ids" are just their names now — downstream code only used the
> old integer ids for truthiness and query scoping, both of which work with names.

### Reading notes

```ruby
db.get_note(note_id)
# => { id:, fields: [ordered array], mod: }   (or nil)

db.find_note_ids('note:"Kaishi 1.5k" deck:"専門用語"')
# => [note ids]   (Anki browser search syntax)

db.find_notes(query)
# => [{ id:, fields: [ordered array], mod: }]

db.notes_in_deck('専門用語', note_type: 'Kaishi 1.5k')
db.notes_in_deck(nil, note_type: 'Kaishi 1.5k', exclude_deck: 'Kaishi 1.5k')
# Convenience wrappers over find_notes. `deck:` includes subdecks (Anki semantics).

db.notes_in_deck_with_deck(deck, note_type:, exclude_deck:)
# => [{ id:, fields:, deck: }]  — adds each note's (first) card deck name,
#    for scripts whose transforms depend on the deck. Uses findCards + cardsInfo.
```

Reads reconstruct the **ordered field array** from the `order` AnkiConnect
returns per field, so they work for any note type without a field-name lookup.

### Card scheduling

```ruby
db.cards_info('deck:"専門用語" prop:ivl>=21')
# => [{ card_id:, note_id:, interval:, due:, deck:, fields: [ordered array] }]

db.set_card_due(card_id, position)   # set a new card's queue position (reordering)
```

### Writing notes

```ruby
db.update_note(note_id, fields)                       # Kaishi by default
db.update_note(note_id, fields, model_name: 'Japanese Katakana')  # other note types
# fields is the ordered array; mapped to a name->value hash via the model's field
# order. No padding/usn/mod needed. Returns true/false.

db.add_note(deck, fields, allow_duplicate: false)     # => new note id, or nil
db.can_add_note?(deck, fields)                         # => true if not a duplicate
db.add_notes(deck, [fields, ...], allow_duplicate:)    # batch; => [ids, nil for dupes]

db.store_media_file(filename, data: bytes)             # or path:  — for audio
```

> **`updateNoteFields` gotcha:** AnkiConnect refuses to update a note that is
> currently open in Anki's Browse window. Close the browser before running
> write scripts.

> **No transactions.** `db.transaction { ... }` exists but only yields — it is
> **not atomic**. Batch creates use `add_notes` (a single request) and stay
> idempotent on re-run (dedup) rather than relying on rollback.

## Field Structure: Kaishi 1.5k Note Type

Project-specific; lives in the `Kaishi` module (`lib/kaishi_fields.rb`), not in
`AnkiConnect`. Scripts reference these as `Kaishi::WORD_IDX`, etc.

| Index | Field Name | Constant | Usage |
|-------|-----------|----------|-------|
| 0 | Word | `Kaishi::WORD_IDX` | Vocabulary word (kanji) |
| 1 | Word Reading | `Kaishi::WORD_READING_IDX` | Hiragana/katakana reading |
| 2 | Word Meaning | `Kaishi::WORD_MEANING_IDX` | English translation |
| 3 | Word Furigana | `Kaishi::WORD_FURIGANA_IDX` | Bracket notation: `漢字[かんじ]` |
| 4 | Word Audio | — | `[sound:filename.wav]` |
| 5 | Sentence | `Kaishi::SENTENCE_IDX` | Japanese example sentence |
| 6 | Sentence Meaning | `Kaishi::SENTENCE_MEANING_IDX` | English translation |
| 7 | Sentence Furigana | `Kaishi::SENTENCE_FURIGANA_IDX` | Bracket notation |
| 8 | Sentence Audio | — | `[sound:filename.wav]` |
| 9 | Notes | `Kaishi::NOTES_IDX` | Additional notes |
| 10–13 | Pitch Accent, Pitch Accent Notes, Frequency, Picture | — | Misc |

`Kaishi::EXPECTED_FIELD_COUNT` is `14`, used only when building a fresh field
array from scratch. On write, `AnkiConnect` maps array indices to field names by
the model's field order, so no padding is required.

## Provenance & metadata tags

Note-level flags live in Anki **tags**, not in embedded HTML comments — tags are
searchable (`tag:generated::pitch-accent`), don't pollute field content, and are
read/written over AnkiConnect (`add_tags` / `remove_tags`; reads carry `:tags`).

| Tag | Meaning | Set by |
|-----|---------|--------|
| `generated::grammar` | Grammar notes added from JMdict | `add-jmdict-grammar-notes.rb` |
| `generated::pitch-accent` | Pitch-accent field auto-generated | `generate-pitch-accent.rb` |
| `pitch-accent::unavailable` | Wadoku has no (unambiguous) entry; an accepted gap | `generate-pitch-accent.rb` |
| `furigana::reviewed` | Sentence furigana passed the LLM review | `generate-furigana.rb` |
| `audio::pending::word` / `audio::pending::sentence` | Clip queued; removed once written (resume marker) | `generate-gemini-audio.rb` |
| `generated::llm-sentence` | Example sentence written from LLM-generated YAML | `lib/sentence_writer.rb` |
| `voice::male` / `voice::female` | TTS voice-gender preference (human-set) | manual; read by both audio scripts |

These replaced older `<!-- ... -->` comment markers; the scripts still read the
old markers as a fallback. `lib/deck_status.rb` defines the tag names and, per
field, what counts as needing work; scripts select notes with it and
`deck-status.rb` counts with it.

## Script Boilerplate Pattern

Scripts that change a deck use `ScriptCLI` (`lib/script_cli.rb`) for their
flags and pre-flight checks, and `DeckStatus` to pick their notes:

```ruby
#!/usr/bin/env ruby
require_relative 'lib/script_cli'
require_relative 'lib/deck_status'

cli = ScriptCLI.new('add-meanings.rb', 'Fills empty Word Meaning fields.')
cli.dry_run                         # --dry-run
cli.limit                           # --limit N
cli.force('Overwrite existing word meanings')
cli.llm(:word_meaning)              # --provider / -m (config/llm-models.yaml)
options = cli.parse!                # -d/--target-deck is required

db = cli.connect!                   # Anki running, note type and deck exist
notes = cli.notes(db).select { |note| options[:force] || DeckStatus.needs_word_meaning?(note) }
notes.each do |note|
  fields = note[:fields]
  # ... modify fields[Kaishi::*_IDX] ...
  db.update_note(note[:id], fields) unless options[:dry_run]
end
```

`--target-deck` is required (add-cards.rb also accepts its YAML file's
`target_deck:`), and the curated `Kaishi 1.5k` deck is refused. Exit statuses
are the same everywhere: 0 success, 1 error, 2 bad options, 3 stopped by a
rate or usage limit (re-run to resume).

## Anki Browser Query Cheatsheet

The query language scopes `find_notes` / `cards_info`:

| Query | Matches |
|-------|---------|
| `note:"Kaishi 1.5k"` | notes of that note type |
| `deck:"専門用語"` | cards/notes in the deck (and subdecks) |
| `-deck:"Kaishi 1.5k"` | everything except that deck |
| `is:new` / `-is:new` | new cards / non-new cards |
| `-is:suspended` | not suspended |
| `prop:ivl>=21` | mature cards (interval ≥ 21 days) |

Quote values containing spaces or non-ASCII; the helpers do this for you.
