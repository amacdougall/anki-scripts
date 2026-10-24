# frozen_string_literal: true

module Workbench
  # The steps the Workbench offers, in the suggested order, as plain data. The
  # command builder (command.rb) turns a step plus submitted values into argv,
  # and the page renders its form from the same entries (via /api/config), so
  # a flag only exists here once.
  #
  # Option types:
  #   flag     checkbox; adds `flag` when checked
  #   toggle   checkbox, on by default; adds `off_flag` when unchecked
  #   integer  number field; adds `flag N` when filled in
  #   choice   select; adds `flag value` (or the choice's own `flag`) unless it's the default
  #   provider select from `providers`; adds --provider unless it's the default
  #   model    select from config/llm-models.yaml for `task`; adds --model unless it's the default
  #   file     select from files matching `globs`; adds `flag path`, or the path alone if `flag` is nil
  #   source   select from the decks holding Takoboto notes; adds `flag deck`
  #
  # `script` names which of a multi-script step's scripts takes the option;
  # nil means the step's only script. `required` options must have a value.
  # `remember` options are saved per deck between sessions (preferences.rb).
  module Steps
    Script = Struct.new(:id, :path, :deck, keyword_init: true)

    Option = Struct.new(:key, :label, :type, :flag, :off_flag, :default, :choices, :help, :script,
                        :task, :providers, :globs, :required, :remember, keyword_init: true) do
      def to_h
        super.compact
      end
    end

    Step = Struct.new(:id, :label, :group, :description, :scripts, :options, :checks, :deps,
                      :dry_run, :optional, :info, keyword_init: true) do
      def option(key)
        options.find { |o| o.key == key }
      end

      def script(id = nil)
        id ? scripts.find { |s| s.id == id } : scripts.first
      end

      def to_h
        super.merge(scripts: scripts.map(&:to_h), options: options.map(&:to_h)).compact
      end
    end

    TRANSLATION_PROVIDERS = %w[claude opencode google].freeze
    LLM_PROVIDERS = %w[claude opencode].freeze

    # generate-gemini-audio.rb's DEFAULT_MODEL, and the models lib/gemini_tts/models.rb prices.
    GEMINI_DEFAULT_MODEL = 'gemini-3.8-flash-lite-tts'
    GEMINI_MODELS = %w[gemini-3.8-flash-lite-tts gemini-3.8-flash-tts gemini-3.1-flash-tts-preview].freeze

    def self.limit(script: nil)
      Option.new(key: 'limit', label: 'Limit', type: :integer, flag: '--limit', script: script,
                 help: 'Process only the first N cards. Empty means all.')
    end

    def self.force(label)
      Option.new(key: 'force', label: label, type: :flag, flag: '--force')
    end

    def self.provider(providers, script: nil)
      Option.new(key: 'provider', label: 'LLM provider', type: :provider, providers: providers,
                 script: script, remember: true)
    end

    def self.model(task, script: nil)
      Option.new(key: 'model', label: 'Model', type: :model, task: task, script: script, remember: true,
                 help: 'From config/llm-models.yaml')
    end

    def self.single(id, path)
      [Script.new(id: id, path: path, deck: true)]
    end

    ALL = [
      Step.new(
        id: 'mined', label: 'Mined cards', group: :in, info: true,
        description: 'Reader tools (Yomitan, HoshiReader, Calibre) create Kaishi 1.5k notes directly in a deck ' \
                     'as you read. Nothing to run here: once cards arrive, start with Strip HTML and Add meanings.',
        scripts: [], options: []
      ),
      Step.new(
        id: 'takoboto', label: 'Pull from Takoboto', group: :in,
        description: 'Takes the words from a Takoboto deck and adds them to the target deck as new Kaishi cards, ' \
                     'with readings and meanings looked up fresh (via add-cards.rb).',
        scripts: single('pull', 'pull-from-takoboto.rb'),
        options: [
          Option.new(key: 'source_deck', label: 'Takoboto deck', type: :source, flag: '--source-deck', required: true),
          Option.new(key: 'cleanup', label: 'Afterward, delete', type: :choice, flag: '--cleanup', default: 'x',
                     required: true, help: 'Answers the clean-up prompt.',
                     choices: [{ value: 'x', label: 'Nothing' }, { value: 't', label: 'The temp file' },
                               { value: 's', label: 'The source deck' },
                               { value: 'b', label: 'The temp file and source deck' }]),
          provider(TRANSLATION_PROVIDERS), model(:word_meaning)
        ]
      ),
      Step.new(
        id: 'word_list', label: 'Add from word list', group: :in, dry_run: true,
        description: 'Adds every word in a YAML file. Only the word is required; readings and meanings come from ' \
                     'JMdict, with an LLM fallback. Put word lists in temp/.',
        scripts: single('add', 'add-cards.rb'),
        options: [
          Option.new(key: 'file', label: 'Word list', type: :file, globs: ['temp/*.yaml'], required: true),
          provider(TRANSLATION_PROVIDERS), model(:word_meaning)
        ]
      ),
      Step.new(
        id: 'strip_html', label: 'Strip HTML', group: :fill, checks: %w[stray_html], dry_run: true,
        description: 'Removes stray HTML that reader tools leave in the Word, Word Furigana, Sentence and ' \
                     'Sentence Furigana fields. Furigana <ruby> tags and <br> line breaks stay.',
        scripts: single('strip', 'strip-word-html.rb'),
        options: [limit]
      ),
      Step.new(
        id: 'sentences', label: 'Example sentences', group: :fill, checks: %w[sentence], dry_run: true,
        description: 'Writes an example sentence for each word that lacks one, as a round trip through YAML so ' \
                     'you can read or edit the sentences before they reach Anki. Dry run previews writing the ' \
                     'sentences already in temp/example-sentences.yaml.',
        scripts: [Script.new(id: 'extract', path: 'extract-words.rb', deck: true),
                  Script.new(id: 'generate', path: 'generate-sentences.rb', deck: false),
                  Script.new(id: 'write', path: 'write-sentences.rb', deck: true)],
        options: [
          provider(LLM_PROVIDERS, script: 'generate'), model(:sentence_generation, script: 'generate'),
          Option.new(key: 'instructions_file', label: 'Prompt', type: :file, flag: '--instructions-file',
                     script: 'generate', globs: ['prompts/*.md', 'prompts/local/*.md'],
                     default: 'prompts/example-sentence-instructions.md', remember: true),
          limit(script: 'generate'),
          Option.new(key: 'pause', label: 'Pause to review the YAML before writing', type: :toggle),
          Option.new(key: 'include_existing', label: 'Include words that already have sentences',
                     type: :flag, flag: '--force', script: 'extract'),
          Option.new(key: 'overwrite', label: 'Start fresh (ignore sentences already generated)',
                     type: :flag, flag: '--overwrite', script: 'generate')
        ]
      ),
      Step.new(
        id: 'meanings', label: 'Add meanings', group: :fill, checks: %w[word_meaning], dry_run: true,
        description: 'Fills an empty Word Meaning from JMdict, with an LLM fallback for words JMdict lacks.',
        scripts: single('meanings', 'add-meanings.rb'),
        options: [provider(TRANSLATION_PROVIDERS), model(:word_meaning), limit,
                  force('Overwrite existing word meanings')]
      ),
      Step.new(
        id: 'sentence_meanings', label: 'Sentence meanings', group: :fill, checks: %w[sentence_meaning],
        deps: %w[sentences], dry_run: true,
        description: "Translates example sentences that have no English yet. The deck's translation notes " \
                     '(prompts/translation/<deck>.md) are added to the prompt when present.',
        scripts: single('sentence_meanings', 'add-sentence-meanings.rb'),
        options: [provider(TRANSLATION_PROVIDERS), model(:sentence_translation), limit,
                  force('Overwrite existing sentence meanings')]
      ),
      Step.new(
        id: 'furigana', label: 'Furigana', group: :fill, checks: %w[furigana furigana_review],
        deps: %w[strip_html sentences], dry_run: true,
        description: 'Writes furigana for the word and sentence with MeCab, then has an LLM check the sentence ' \
                     'readings in context, with JMdict readings and the deck’s name readings as hints.',
        scripts: single('furigana', 'generate-furigana.rb'),
        options: [
          provider(LLM_PROVIDERS), model(:furigana_review),
          Option.new(key: 'review_jobs', label: 'Review batches at once', type: :integer, flag: '--review-jobs',
                     help: 'Default 4.'),
          limit,
          Option.new(key: 'review', label: 'LLM review', type: :toggle, off_flag: '--no-review'),
          Option.new(key: 'review_unreviewed', label: 'Only review furigana not yet reviewed',
                     type: :flag, flag: '--review-unreviewed'),
          force('Regenerate existing furigana (and review it again)')
        ]
      ),
      Step.new(
        id: 'pitch_accent', label: 'Pitch accent', group: :fill, checks: %w[pitch_accent], deps: %w[strip_html],
        dry_run: true,
        description: 'Draws the pitch-accent diagram from Wadoku’s data. Words Wadoku can’t cover are tagged ' \
                     'pitch-accent::unavailable and don’t count as missing.',
        scripts: single('pitch', 'generate-pitch-accent.rb'),
        options: [limit, force('Regenerate existing pitch accent, and retry unavailable words')]
      ),
      Step.new(
        id: 'grammar_notes', label: 'Grammar notes', group: :fill, checks: %w[grammar_notes], deps: %w[strip_html],
        dry_run: true,
        description: 'Appends short JMdict grammar notes (part of speech, usage) to the Notes field.',
        scripts: single('grammar', 'add-jmdict-grammar-notes.rb'),
        options: [limit, force('Re-process notes already done')]
      ),
      Step.new(
        id: 'sort', label: 'Sort by frequency', group: :fill, optional: true, dry_run: true,
        description: 'Reorders the deck’s unseen cards so the most common words come up first, by word frequency.',
        scripts: single('sort', 'sort-new-by-word-frequency.rb'),
        options: []
      ),
      Step.new(
        id: 'audio', label: 'Generate audio', group: :fill, checks: %w[word_audio sentence_audio],
        deps: %w[sentences furigana], dry_run: true,
        description: 'Generates word and sentence audio with Gemini TTS, then checks each clip’s reading with ' \
                     'Whisper. Clips Gemini’s content filter blocks fall back to VOICEVOX when its server is running.',
        scripts: single('audio', 'generate-gemini-audio.rb'),
        options: [
          Option.new(key: 'clips', label: 'Clips', type: :choice, default: 'both',
                     choices: [{ value: 'both', label: 'Word and sentence' },
                               { value: 'word', label: 'Word only', flag: '--word-only' },
                               { value: 'sentence', label: 'Sentence only', flag: '--sentence-only' }]),
          Option.new(key: 'model', label: 'Gemini TTS model', type: :choice, flag: '--model',
                     default: GEMINI_DEFAULT_MODEL, remember: true,
                     choices: GEMINI_MODELS.map { |m| { value: m, label: m } }),
          Option.new(key: 'jobs', label: 'Clips at once', type: :integer, flag: '--jobs',
                     help: 'Default 8. Lower it if you hit rate limits.'),
          Option.new(key: 'whisper_jobs', label: 'Whisper transcriptions at once', type: :integer,
                     flag: '--whisper-jobs', help: 'Default 2.'),
          limit,
          Option.new(key: 'reading_check', label: 'Whisper reading check', type: :toggle,
                     off_flag: '--no-reading-check'),
          Option.new(key: 'check_existing', label: 'Check existing audio instead of generating',
                     type: :flag, flag: '--check-existing'),
          Option.new(key: 'voicevox_fallback', label: 'VOICEVOX fallback for blocked clips', type: :toggle,
                     off_flag: '--no-voicevox-fallback'),
          force('Regenerate audio that already exists')
        ]
      )
    ].freeze

    def self.find(id)
      ALL.find { |step| step.id == id }
    end
  end
end
