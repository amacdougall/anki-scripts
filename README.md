# Anki Example Sentence Builder

Ruby scripts that turn a bare list of Japanese words into full
[Kaishi 1.5k](https://ankiweb.net/shared/info/1196762551)-style Anki cards:
reading, English meaning, an example sentence and its translation, furigana,
pitch accent, grammar notes, and natural-sounding audio for both the word and
the sentence.

Words can come from a YAML list, from the Takoboto dictionary app, or from cards
you mine while reading (Yomitan, HoshiReader, Calibre, or anything with an Anki
integration). Whatever the source, the same set of scripts fills in everything
the card is missing.

These are scripts for technical users, not a polished app. You'll be running
them from a terminal, and you'll get the most out of them if you're happy to
read a `--help` or hand a script to Claude Code and ask what it does.

## Requirements

- **Ruby 3.2+** with Bundler.
- **Anki** (desktop) with the
  [**AnkiConnect**](https://ankiweb.net/shared/info/2055492159) add-on.
  Every script talks to Anki through AnkiConnect, so **Anki must be running**
  whenever you run a script.
- **The [Kaishi 1.5k](https://ankiweb.net/shared/info/1196762551) deck**,
  installed in Anki. The scripts create and fill cards of its `Kaishi 1.5k`
  note type, and expect its 14 fields as they ship. (You don't have to study
  the deck itself... but you should!)
- **An LLM CLI**: [Claude Code](https://claude.com/claude-code) (`claude`) or
  [OpenCode](https://opencode.ai) (`opencode`), logged in. Used to write
  example sentences, translate them, and review furigana. The scripts use
  whatever account the CLI is logged into; there are no API keys to manage.
- **A Gemini API key**, for audio. See [Audio](#3-audio).
- **Optional:** [Whisper](#whisper-reading-check) (an audio double-check) and
  [VOICEVOX](https://voicevox.hiroshiba.jp/) (an older, free audio engine).

MeCab, the Japanese tokenizer used for furigana, is bundled for macOS, Linux
and Windows; you don't need to install it.

## Setup

```sh
./bootstrap.rb
```

This installs the gems, downloads the dictionaries into `data/` (about 500 MB
on disk), and then checks your environment: whether Anki and AnkiConnect are
reachable, whether the Kaishi 1.5k note type has the expected fields, and
which of `claude`/`opencode`, the Gemini key and Whisper it can find. It's safe
to re-run, and `./bootstrap.rb --check` repeats just the checks.

### Gemini API key

Create a key in [Google AI Studio](https://aistudio.google.com/apikey), then
either export it:

```sh
export GEMINI_API_KEY=...
```

or save it where the scripts will find it:

```sh
mkdir -p ~/.config/gemini
pbpaste > ~/.config/gemini/api_key   # or write it any other way
chmod 600 ~/.config/gemini/api_key
```

The free tier allows only 100 requests a day, which is about 50 cards. To lift
that cap, set up billing and pre-fund the account; Google auto-approves the
next service tier after about 24 hours. It's a hassle, but worth it (see
[Audio](#3-audio)).

## How the scripts work

**One deck per source.** My workflow is built around one deck per source of
vocabulary: a deck for each book, show, or topic (`とらドラ！`, `呪術廻戦`,
`Work Words`). That keeps related words together, and lets each deck have its
own [name readings and translation notes](#per-deck-customization). The
scripts work fine with one big deck too.

**Scope.** Most scripts take `--target-deck DECK`. Without it, they work on
every Kaishi 1.5k card in your collection **except** the deck named
`Kaishi 1.5k` itself, which is already complete. If you renamed that deck,
always pass `--target-deck`, or the scripts will treat its cards as yours.

**They only fill in what's missing.** Each script skips cards that already have
the field it writes, so re-running is safe and cheap. `--force` regenerates
existing values. Most scripts also take `--dry-run` (preview without writing)
and `--limit N` (process only N cards); run any script with `-h` for its flags.

**Back up before bulk changes.** Anki does every write itself, so there's no
risk of corrupting the collection, but there's also no undo for a script that
just rewrote 500 cards. Before a big run, quit Anki and snapshot the collection:

```sh
./backup-collection.sh    # copies it into backups/, keeping the last 5
```

It finds the collection in Anki's default location for your OS. Set
`ANKI_PROFILE` if your profile isn't called `User 1`, or `ANKI_BASE` if Anki's
data lives somewhere else.

**Close the Browse window.** AnkiConnect can't update a note that's open in
Anki's card browser.

## 1. Getting words in

### From a word list

```sh
cp examples/incoming-words.yaml temp/incoming-words.yaml   # then edit it
./add-cards.rb temp/incoming-words.yaml
```

The YAML file names the target deck (`target_deck:`, or pass `--target-deck`),
and lists the words. Only `word` is required; readings and meanings are looked
up in JMdict, with an LLM translation as a fallback for words JMdict doesn't
know. You can also supply the sentence you found the word in. See
[`examples/incoming-words.yaml`](examples/incoming-words.yaml) for every
field. The deck must already exist, and words already in your collection
(same word and reading) are skipped. Add `--dry-run` to preview the lookups.

### From Takoboto

[Takoboto](https://takoboto.jp/), a dictionary app, can send the words
you look up to an Anki deck, using its own `jp.takoboto` note type. Its
readings, meanings and sentences aren't what we want, but it's a handy way to
collect words, and it knows more phrases and idioms than JMdict.

```sh
./pull-from-takoboto.rb --source 'Takoboto 呪術廻戦' --target $TARGET_DECK
```

This takes just the words from the Takoboto deck, adds them to the target deck
as new Kaishi 1.5k cards (via `add-cards.rb`, so everything is looked up
fresh), and then offers to delete the source deck. Deleting it is safe, since
Takoboto can recreate it.

### Mined cards

Reader tools can create cards as you read: [Yomitan](https://yomitan.wiki/)
in the browser, HoshiReader, or Calibre. Set the tool to create **Kaishi 1.5k**
notes and map at least `Word`, `Word Reading` and `Sentence`. The scripts below
fill in the rest.

A note on meanings: I leave Yomitan's and HoshiReader's meaning fields unmapped
and let `add-meanings.rb` fill `Word Meaning` from JMdict, because their
dictionary output doesn't suit the card. The meanings from my customized
Calibre are fine, so I keep those. Your mileage may vary.

## 2. The common workflow

Run these against a deck after adding words, by whatever route. Set
`TARGET_DECK` to the deck's name first.

Clean up stray HTML that reader tools leave in the Word field:

```sh
./strip-word-html.rb
```

### Example sentences

For words without an example sentence, write one with an LLM. This is a
three-step round trip through a YAML file, so you can read or edit the
sentences before they go into Anki:

```sh
./extract-words.rb \
  --output temp/words.yaml \
  --target-deck $TARGET_DECK

rm temp/example-sentences.yaml   # if starting fresh

./generate-sentences.rb \
  --provider claude --model sonnet \
  --input temp/words.yaml \
  --output temp/example-sentences.yaml \
  --instructions-file prompts/example-sentence-instructions.md \
  --verbose

./write-sentences.rb \
  --input temp/example-sentences.yaml
```

`generate-sentences.rb` saves after every word, and if it's interrupted, a
re-run picks up where it left off; that's why you delete the output file to
start fresh. The prompt is in
[`prompts/example-sentence-instructions.md`](prompts/example-sentence-instructions.md).
Copy and adjust it for a deck that needs a different flavor (technical
vocabulary, a manga's setting) and pass the copy as `--instructions-file`.

### Meanings, furigana, pitch accent, grammar notes

In almost every case, run:

```sh
./add-meanings.rb --target-deck $TARGET_DECK   # if needed
./add-sentence-meanings.rb --provider claude --model sonnet --target-deck $TARGET_DECK
./generate-furigana.rb --target-deck $TARGET_DECK --provider claude --model sonnet
./generate-pitch-accent.rb
./add-jmdict-grammar-notes.rb
```

| Script | What it does |
| --- | --- |
| `add-meanings.rb` | Fills an empty Word Meaning from JMdict (LLM fallback), and an empty Word Reading too. Needed for some mined cards; cards from `add-cards.rb` already have both. |
| `add-sentence-meanings.rb` | Translates sentences that have no English yet. |
| `generate-furigana.rb` | Writes furigana for the word and sentence with MeCab, then has an LLM check the sentence readings in context. MeCab gives each word one reading regardless of context (身体 as しんたい where the sentence means からだ); the review catches these, with JMdict's readings as a reference. |
| `generate-pitch-accent.rb` | Draws the pitch-accent diagram from Wadoku's data. (You'll want to enable pitch accent display in the Kaishi note template or this will have no visible effect.) It has no `--target-deck`; it covers every card in scope, and skips words Wadoku doesn't know. |
| `add-jmdict-grammar-notes.rb` | Adds short grammar notes from JMdict to the Notes field: transitive or intransitive, な/い adjective, counter, onomatopoeia, honorific, and so on. |

`--provider` takes `claude` or `opencode`. Without it, the scripts use
OpenCode with a small, cheap model; `claude --model sonnet` is more careful but
uses your Claude plan's usage. Default models are set in
[`lib/llm_defaults.rb`](lib/llm_defaults.rb).

### Sorting by frequency (optional)

```sh
./sort-new-by-word-frequency.rb --target-deck $TARGET_DECK
```

This reorders a deck's unstudied cards so the most common words come up first,
using JPDB frequency ranks. It's here if you want it; I've stopped using it,
because I like my words to come up in the order I added them.

## 3. Audio

```sh
./generate-gemini-audio.rb
```

This generates word and sentence audio for every card missing it, with Gemini
text-to-speech. Each clip gets a random voice from a pool of standard Tokyo
Japanese voices (tag a note `voice::male` or `voice::female` to choose). Words
are spoken with the card's reading as a pronunciation hint, and deck name
readings are applied first.

The Gemini voices are far better than anything else I've tried: natural,
varied, and accurate enough to learn pitch accent from. They're well worth
the hassle of setting up the [API key](#gemini-api-key). The default model
(`gemini-3.8-flash-lite-tts`) costs about $1.30 per 1,000 cards (word plus
sentence) at launch pricing, which runs through 2026-12-31 and doubles after.
Literally a bargain at twice the price.

Useful flags: `--target-deck`, `--word-only`, `--sentence-only`, `--limit`,
`--jobs N` (concurrent requests, default 8; lower it if you hit rate limits),
and `--dry-run`. An interrupted run resumes where it left off: re-run the same
command.

Gemini's content filter occasionally blocks a harmless sentence. If a
[VOICEVOX](#voicevox) server is running, those clips are voiced with VOICEVOX
instead; otherwise they're listed at the end and left for later.

### Whisper reading check

TTS voices sometimes misread kanji (卓袱台 as たくぶだい). With
[Whisper](https://github.com/ggml-org/whisper.cpp) installed, the script
transcribes every clip it generates, compares what it hears with the card's
furigana, and regenerates misread clips with the troublesome words in kana.
This catches a surprising number of errors.

```sh
./setup-whisper.sh
```

On macOS this installs `whisper-cpp` with Homebrew. Elsewhere it builds
whisper.cpp from source, which needs git, cmake and a C++ compiler. Either way
it then downloads the large-v3-turbo model (about 1.6 GB) into `data/whisper/`.
If you already have the model, export `WHISPER_MODEL=/path/to/ggml-large-v3-turbo.bin`
(in your shell profile, so the audio script sees it too) to skip the download.

Without Whisper, the audio script simply skips the check. To check audio
that's already on your cards, run `./generate-gemini-audio.rb --check-existing`.

### VOICEVOX

```sh
./generate-voicevox-audio.rb --target-deck $TARGET_DECK
```

The older audio path, using a local [VOICEVOX](https://voicevox.hiroshiba.jp/)
server. It's free, but noticeably more robotic than Gemini. It takes the same
flags as the Gemini script (minus `--model`). It expects the server at
`http://127.0.0.1:50021`; set `VOICEVOX_URL` if it runs elsewhere.

## Per-deck customization

Since each deck usually comes from one book or show, a few things can be set
per deck:

- **Name readings** — `config/deck-readings.yaml`. Character names often have
  unusual readings that MeCab and the TTS voices get wrong (悠仁 is ゆうじ,
  not ゆうひとし). List them per deck, and they're used for furigana, as hints
  for the LLM review and translation, and spoken correctly in audio. Copy
  [`config/deck-readings.example.yaml`](config/deck-readings.example.yaml) to
  start.
- **Translation notes** — `prompts/translation/<deck name>.md`. Added to the
  prompt when `add-sentence-meanings.rb --target-deck` translates that deck's
  sentences with an LLM: who's male or female, how to render recurring terms, the tone. See
  [`prompts/translation/とらドラ！.md`](prompts/translation/とらドラ！.md).
- **Sentence prompt** — a copy of the example-sentence prompt, passed to
  `generate-sentences.rb --instructions-file`.

## Other scripts

```sh
./backup-collection.sh    # snapshot the collection (quit Anki first)
./export-seen-words.rb    # every word you've studied, for the curious
```

`export-seen-words.rb` writes every word on a Kaishi card you've studied
(neither new nor suspended) to `data/seen-words.txt`, and their kanji to
`data/seen-kanji.txt`. Use `--exclude-deck` to leave out decks.

[`doc/anki-interaction.md`](doc/anki-interaction.md) describes how the scripts
talk to Anki, the Kaishi field layout, and the tags they use, if you want to
write your own.

## Data sources and credits

`bootstrap.rb` downloads these; none are redistributed in this repository.

- **[JMdict](https://www.edrdg.org/jmdict/j_jmdict.html)** and
  **[KANJIDIC2](https://www.edrdg.org/wiki/index.php/KANJIDIC_Project)**, from
  the Electronic Dictionary Research and Development Group, used under the
  [EDRDG licence](https://www.edrdg.org/edrdg/licence.html) (CC BY-SA 4.0).
  JMdict comes via [jmdict-simplified](https://github.com/scriptin/jmdict-simplified).
- **Pitch accent** data from [Wadoku](https://www.wadoku.de/) by Ulrich Apel,
  as extracted by [anki_add_pitch_plugin](https://github.com/IllDepence/anki_add_pitch_plugin).
  See the [Wadoku license](https://www.wadoku.de/wiki/display/WAD/W%C3%B6rterbuch+Lizenz).
- **[UniDic](https://clrd.ninjal.ac.jp/unidic/)** (via the
  [unidic-lite](https://pypi.org/project/unidic-lite/) package), for MeCab.
- **Word frequency** from the JPDB v2 frequency dictionary, via
  [Kuuuube/yomitan-dictionaries](https://github.com/Kuuuube/yomitan-dictionaries).

[MeCab](https://taku910.github.io/mecab/) binaries are bundled in
`support/mecab/`, under MeCab's BSD license (`support/mecab/BSD`). The card format is
[Kaishi 1.5k](https://github.com/donkuri/kaishi)'s.
