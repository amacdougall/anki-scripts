# frozen_string_literal: true

require 'rbconfig'
require_relative 'steps'
require_relative '../lib/llm_config'

module Workbench
  # Builds the argv arrays for one run of a step from the values the page
  # submitted. Never builds a shell string: the runner spawns these arrays
  # directly, and #display renders the same arrays for the command preview, so
  # what the page shows is what runs.
  #
  #   plan = Command.build('furigana', deck: '呪術廻戦', values: { 'limit' => '5' }, context: context)
  #   plan.invocations # => [#<Invocation script_id="furigana" argv=[ruby, ".../generate-furigana.rb", ...]>]
  #
  # Raises Command::Invalid (with a message for the page) for anything the
  # registry or the context doesn't allow.
  module Command
    ROOT = File.expand_path('..', __dir__)
    CURATED_DECK = 'Kaishi 1.5k'

    class Invalid < StandardError; end

    # What a step's values are checked against. decks: every deck name in
    # Anki; takoboto_decks: the decks holding Takoboto notes. Files are checked
    # against the step's globs on disk.
    Context = Struct.new(:decks, :takoboto_decks, :root, keyword_init: true) do
      def initialize(decks: [], takoboto_decks: [], root: ROOT)
        super
      end

      # Repo-relative paths matching globs, sorted.
      def files(globs)
        globs.flat_map { |glob| Dir.glob(glob, base: root) }.sort.uniq
      end
    end

    Invocation = Struct.new(:script_id, :argv, keyword_init: true) do
      # The command as a person would type it: ./script.rb --flag value ...
      def display
        script, *args = argv.first == RbConfig.ruby ? argv[1..] : argv
        ["./#{File.basename(script)}", *args].map { |arg| Command.quote(arg) }.join(' ')
      end
    end

    Plan = Struct.new(:step, :deck, :dry_run, :phase, :invocations, keyword_init: true) do
      def displays
        invocations.map(&:display)
      end
    end

    # Phases of the Example sentences step: generate stops before writing
    # (the review pause), write is the second half, all runs the three scripts.
    PHASES = %w[all generate write].freeze

    module_function

    def build(step_id, deck:, values: {}, context:, dry_run: false, phase: nil)
      step = Steps.find(step_id.to_s) or raise Invalid, "Unknown step: #{step_id}"
      raise Invalid, "#{step.label} has nothing to run" if step.scripts.empty?
      raise Invalid, "#{step.label} has no dry run" if dry_run && !step.dry_run

      validate_deck!(deck, context)
      values = normalize(step, values || {})
      phase = resolve_phase(step, values, phase, dry_run)

      invocations = scripts_for(step, phase).map do |script|
        argv = [RbConfig.ruby, File.join(context.root, script.path)]
        argv.push('--target-deck', deck) if script.deck
        argv.concat(args_for(step, script, values, context))
        argv << '--dry-run' if dry_run
        Invocation.new(script_id: script.id, argv: argv)
      end
      Plan.new(step: step, deck: deck, dry_run: dry_run, phase: phase, invocations: invocations)
    end

    # Shell-style quoting for display only.
    def quote(arg)
      arg.match?(%r{\A[\w./:=@+,-]+\z}) ? arg : "'#{arg.gsub("'") { %q('\\'') }}'"
    end

    def validate_deck!(deck, context)
      raise Invalid, 'Choose a target deck' if deck.to_s.strip.empty?
      raise Invalid, "'#{CURATED_DECK}' is the curated source deck; scripts don't modify it" if deck == CURATED_DECK
      raise Invalid, "No such deck: #{deck}" unless context.decks.include?(deck)
    end

    # Only known keys, with checkbox values as booleans and blanks dropped.
    def normalize(step, values)
      values = values.transform_keys(&:to_s)
      unknown = values.keys - step.options.map(&:key)
      raise Invalid, "#{step.label} has no option #{unknown.join(', ')}" unless unknown.empty?

      step.options.to_h do |option|
        value = values[option.key]
        value = value.strip if value.is_a?(String)
        value = nil if value == ''
        value = boolean(option, value) if %i[flag toggle].include?(option.type)
        [option.key, value]
      end
    end

    def boolean(option, value)
      return option.type == :toggle if value.nil?
      return value if [true, false].include?(value)
      return true if %w[true 1 on].include?(value.to_s)
      return false if %w[false 0 off].include?(value.to_s)

      raise Invalid, "#{option.label}: expected true or false"
    end

    def resolve_phase(step, values, phase, dry_run)
      return nil unless step.id == 'sentences'
      return 'write' if dry_run
      raise Invalid, "Unknown phase: #{phase}" if phase && !PHASES.include?(phase)

      phase || (values['pause'] ? 'generate' : 'all')
    end

    def scripts_for(step, phase)
      case phase
      when 'write' then [step.script('write')]
      when 'generate' then [step.script('extract'), step.script('generate')]
      else step.scripts
      end
    end

    def args_for(step, script, values, context)
      options = step.options.select { |o| o.script.nil? || o.script == script.id }
      options.flat_map { |option| option_args(option, values[option.key], values, context) }
    end

    def option_args(option, value, values, context)
      raise Invalid, "#{option.label} is required" if option.required && value.nil? && option.default.nil?

      case option.type
      when :flag then value ? [option.flag] : []
      when :toggle then !value && option.off_flag ? [option.off_flag] : []
      when :integer then integer_args(option, value)
      when :choice then choice_args(option, value)
      when :provider then provider_args(option, value)
      when :model then model_args(option, value, values['provider'])
      when :file then file_args(option, value, context)
      when :source then source_args(option, value, context)
      else raise ArgumentError, "unknown option type #{option.type}"
      end
    end

    def integer_args(option, value)
      return [] if value.nil?
      raise Invalid, "#{option.label} must be a whole number above 0" unless value.to_s.match?(/\A[1-9]\d{0,6}\z/)

      [option.flag, value.to_s]
    end

    def choice_args(option, value)
      value ||= option.default
      choice = option.choices.find { |c| c[:value] == value } or raise Invalid, "#{option.label}: unknown choice #{value}"
      return [choice[:flag]] if choice[:flag]
      return [] if option.flag.nil? || (value == option.default && !option.required)

      [option.flag, value]
    end

    def provider_args(option, value)
      return [] if value.nil? || value == LlmConfig.default_provider
      raise Invalid, "#{option.label}: unknown provider #{value}" unless option.providers.include?(value)

      ['--provider', value]
    end

    def model_args(option, value, provider)
      provider ||= LlmConfig.default_provider
      return [] if value.nil?
      raise Invalid, "#{option.label} doesn't apply to provider #{provider}" if provider == 'google'
      raise Invalid, "#{option.label}: #{value} isn't listed for #{provider}" unless LlmConfig.models(provider).include?(value)
      return [] if value == LlmConfig.default_model(option.task, provider)

      ['--model', value]
    end

    def file_args(option, value, context)
      return [] if value.nil? || (value == option.default && option.flag)
      raise Invalid, "#{option.label}: #{value} isn't one of the files offered" unless context.files(option.globs).include?(value)

      option.flag ? [option.flag, value] : [value]
    end

    def source_args(option, value, context)
      raise Invalid, "#{option.label} is required" if value.nil?
      raise Invalid, "#{option.label}: #{value} holds no Takoboto notes" unless context.takoboto_decks.include?(value)

      [option.flag, value]
    end
  end
end
