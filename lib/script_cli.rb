# frozen_string_literal: true

require 'optparse'
require_relative 'anki_connect'
require_relative 'kaishi_fields'
require_relative 'llm_config'
require_relative 'progress_reporter'

# Command-line handling shared by the scripts that change an Anki deck, so they
# all take the same flags, check the same things before touching Anki, and exit
# with the same statuses.
#
#   cli = ScriptCLI.new('add-meanings.rb', 'Fills empty Word Meaning fields from JMdict.')
#   cli.dry_run
#   cli.limit
#   cli.force('Overwrite existing word meanings')
#   cli.llm(:word_meaning, providers: %w[claude opencode google])
#   cli.on('--ruby-only', 'Only words with <ruby> furigana') { cli.options[:ruby_only] = true }
#   options = cli.parse!
#   db = cli.connect!
#   notes = cli.notes(db)
#
# Every script gets -d/--target-deck and -h/-?. The deck is required unless the
# script passes deck: :optional (add-cards.rb, whose YAML file may name it
# instead), and the curated 'Kaishi 1.5k' deck is always refused as a target.
class ScriptCLI
  # Write output as it happens, even into a pipe, so a tool running a script
  # (the planned Workbench, or `| tee`) sees progress line by line.
  $stdout.sync = true

  # Exit statuses, the same for every script.
  EXIT_OK = 0
  EXIT_ERROR = 1 # something failed: a card, a lookup, Anki
  EXIT_USAGE = 2 # bad or missing options
  EXIT_LIMIT = 3 # stopped early by a rate or usage limit; re-run to resume

  # The deck the Kaishi 1.5k cards ship in. It's already complete, so scripts
  # never modify it.
  CURATED_DECK = Kaishi::NOTE_TYPE_NAME

  attr_reader :options

  def initialize(script, *description, deck: :required, usage: nil)
    @script = script
    @deck = deck
    @options = { target_deck: nil, dry_run: false, limit: nil, force: false }
    @parser = OptionParser.new
    @parser.banner = "Usage: #{script} #{usage || default_usage}"
    unless description.empty?
      @parser.separator ''
      description.each { |line| @parser.separator line }
    end
    @parser.separator ''
    @parser.separator 'Options:'
    deck_help = deck == :required ? 'Deck to work on (required)' : 'Deck to work on'
    @parser.on('-d', '--target-deck DECK', deck_help) { |d| @options[:target_deck] = d }
  end

  def dry_run(help = 'Preview changes without modifying Anki')
    @parser.on('--dry-run', help) { @options[:dry_run] = true }
  end

  def limit(help = 'Process only the first N notes')
    @parser.on('--limit N', Integer, help) { |n| @options[:limit] = n }
  end

  def force(help)
    @parser.on('--force', help) { @options[:force] = true }
  end

  # Adds --provider and -m/--model for an LLM task (see LlmConfig::TASKS).
  # providers lists what this script accepts; 'google' (Google Translate) has
  # no models. Without --model, options[:model] is the task's default for the
  # chosen provider (nil for google).
  def llm(task, providers: LlmConfig.providers, help: 'LLM provider')
    @llm_task = task
    @llm_providers = providers
    @options[:provider] = LlmConfig.default_provider
    @options[:model] = nil
    defaults = (providers & LlmConfig.providers).map { |p| "#{LlmConfig.default_model(task, p)} for #{p}" }
    @parser.on('--provider PROVIDER', "#{help}: #{providers.join(', ')} (default: #{LlmConfig.default_provider})") do |p|
      @options[:provider] = p
    end
    @parser.on('-m', '--model MODEL', "Model (default: #{defaults.join('; ')}; see config/llm-models.yaml)") do |m|
      @options[:model] = m
    end
  end

  # Any other flag; the block gets the value OptionParser parsed.
  def on(*args, &block)
    @parser.on(*args, &block)
  end

  def separator(text = '')
    @parser.separator(text)
  end

  def help
    @parser.help
  end

  def parse!(argv = ARGV)
    @parser.on('-h', '--help', '-?', 'Show this message') do
      puts @parser
      exit EXIT_OK
    end
    @parser.parse!(argv)
    validate!
    @options
  rescue OptionParser::ParseError => e
    usage_error(e.message)
  end

  # Prints a usage error and exits with EXIT_USAGE. Scripts call this for their
  # own option checks too.
  def usage_error(message)
    warn "Error: #{message}"
    warn "Run #{@script} -h for usage."
    exit EXIT_USAGE
  end

  # Checks that Anki is running, the Kaishi note type exists and the target deck
  # exists, printing what it found unless quiet.
  # Exits EXIT_ERROR if any check fails. Returns a connected AnkiConnect.
  def connect!(quiet: false)
    AnkiConnect.require_running!
    db = AnkiConnect.new.connect
    ProgressReporter.success('Connected to Anki via AnkiConnect') unless quiet

    unless db.find_note_type_id(Kaishi::NOTE_TYPE_NAME)
      ProgressReporter.error("Note type not found: #{Kaishi::NOTE_TYPE_NAME}")
      exit EXIT_ERROR
    end

    deck = @options[:target_deck]
    if deck && !db.find_deck_id(deck)
      ProgressReporter.error("Deck not found: #{deck}")
      exit EXIT_ERROR
    end
    unless quiet
      puts "Target deck: #{deck}" if deck
      puts ''
    end
    db
  end

  # The target deck's Kaishi notes (subdecks included). with_deck: true adds
  # each note's deck name as :deck, for per-deck TextTransforms.
  def notes(db, with_deck: false)
    deck = @options[:target_deck]
    if with_deck
      db.notes_in_deck_with_deck(deck, note_type: Kaishi::NOTE_TYPE_NAME)
    else
      db.notes_in_deck(deck, note_type: Kaishi::NOTE_TYPE_NAME)
    end
  end

  # Stops the script after a rate or usage limit, with a hint to re-run.
  def self.limit_reached!(message, resume: nil)
    ProgressReporter.error(message)
    puts "Re-run#{" #{resume}" if resume} once the limit resets to pick up where this run stopped."
    exit EXIT_LIMIT
  end

  private

  def default_usage
    @deck == :required ? '--target-deck DECK [options]' : '[options]'
  end

  def validate!
    deck = @options[:target_deck]
    usage_error('--target-deck is required') if @deck == :required && blank?(deck)
    usage_error("'#{CURATED_DECK}' is the curated source deck; scripts don't modify it") if deck == CURATED_DECK
    validate_llm! if @llm_task
  end

  def validate_llm!
    provider = @options[:provider]
    usage_error("--provider must be one of: #{@llm_providers.join(', ')}") unless @llm_providers.include?(provider)
    if provider == 'google'
      usage_error('--model does not apply to --provider google') if @options[:model]
    else
      @options[:model] ||= LlmConfig.default_model(@llm_task, provider)
    end
  end

  def blank?(value)
    value.nil? || value.strip.empty?
  end
end
