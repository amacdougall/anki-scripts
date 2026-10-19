#!/usr/bin/env ruby

require 'optparse'
require 'set'
require_relative 'lib/yaml_loader'
require_relative 'lib/sentence_generator'
require_relative 'lib/claude_interface'
require_relative 'lib/opencode_interface'
require_relative 'lib/llm_config'
require_relative 'lib/script_cli'
require_relative 'lib/incremental_yaml_writer'

class GenerateSentences
  DEFAULT_INPUT = File.join(__dir__, 'temp', 'words.yaml')
  DEFAULT_OUTPUT = File.join(__dir__, 'temp', 'example-sentences.yaml')
  DEFAULT_INSTRUCTIONS = File.join(__dir__, 'prompts', 'example-sentence-instructions.md')

  def initialize(argv)
    @options = parse_options(argv)
    @stats = {
      total: 0,
      successful: 0,
      failed: 0,
      skipped: 0
    }
  end

  def run
    # Load input
    input_data = YamlLoader.load_words(@options[:input])
    instructions = load_instructions

    # Initialize generator
    llm = build_llm
    generator = SentenceGenerator.new(instructions, llm: llm)

    # Automatically resume from any existing output unless --overwrite given.
    # Only notes that previously succeeded, and are still in the input, are
    # carried over; not-yet-seen and previously-errored notes are (re)processed.
    # (Notes from another deck's run, or already written to Anki and so no
    # longer extracted, are dropped.)
    existing_notes = @options[:overwrite] ? [] : load_existing_output
    input_ids = Set.new(input_data['notes'].map { |n| n['note_id'] })
    completed_notes = existing_notes.select { |n| n['generation_status'] == 'success' && input_ids.include?(n['note_id']) }
    processed_note_ids = Set.new(completed_notes.map { |n| n['note_id'] })

    # Initialize output writer
    metadata = build_metadata(input_data)
    writer = IncrementalYamlWriter.new(@options[:output], metadata)

    # Carry over already-completed notes so they survive the rewrite.
    completed_notes.each { |note| writer.add_note(note) }

    # Process notes
    notes_to_process = select_notes_to_process(input_data['notes'], processed_note_ids)

    if completed_notes.any?
      puts "Resuming: #{completed_notes.length} note(s) already done in #{@options[:output]}."
    end
    puts "Processing #{notes_to_process.length} note(s)..."
    puts "Output file: #{@options[:output]}"
    puts

    notes_to_process.each_with_index do |note, idx|
      @stats[:total] += 1

      meaning = note['word_meaning']
      print "[#{idx + 1}/#{notes_to_process.length}] #{note['word']} (#{meaning[0, 50]}#{'...' if meaning.length > 50})... "

      begin
        # Generate sentences
        sentence_data = generator.generate_for_note(note)

        # Merge with original note
        result_note = note.merge(sentence_data)
        result_note['generation_status'] = 'success'

        # Save to output
        writer.add_note(result_note)

        @stats[:successful] += 1
        puts "✓"

      rescue LLMInterface::UsageLimitError => e
        puts "✗"
        print_summary
        ScriptCLI.limit_reached!("#{@options[:provider]} usage limit reached: #{e.message[0, 200]}",
                                 resume: 'the same command')
      rescue SentenceGenerator::GenerationError => e
        # Log error and continue
        error_note = note.dup
        error_note['generation_status'] = 'error'
        error_note['generation_error'] = e.message

        writer.add_note(error_note)

        @stats[:failed] += 1
        puts "✗ (#{e.message})"
      end

      # Update metadata with current stats
      writer.update_metadata({
        'total_processed' => @stats[:total],
        'successful' => @stats[:successful],
        'failed' => @stats[:failed]
      })
    end

    # Print summary
    print_summary
    exit(@stats[:failed] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)
  end

  private

  def parse_options(argv)
    options = {
      input: DEFAULT_INPUT,
      output: DEFAULT_OUTPUT,
      instructions: DEFAULT_INSTRUCTIONS,
      overwrite: false,
      limit: nil,
      verbose: false,
      provider: LlmConfig.default_provider,
      model: nil
    }

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: generate-sentences.rb [options]"
      opts.separator ""
      opts.separator "Generate example sentences using an LLM for vocabulary words."
      opts.separator ""
      opts.separator "Options:"

      opts.on('-i', '--input FILE', "Input YAML file (default: temp/words.yaml)") do |file|
        options[:input] = file
      end

      opts.on('-o', '--output FILE', "Output YAML file (default: temp/example-sentences.yaml)") do |file|
        options[:output] = file
      end

      opts.on('-p', '--instructions-file FILE', "Prompt template file (default: prompts/example-sentence-instructions.md)") do |file|
        options[:instructions] = file
      end

      opts.on('--overwrite', 'Ignore existing output and regenerate all notes from scratch') do
        options[:overwrite] = true
      end

      opts.on('-l', '--limit N', Integer, 'Only process first N notes (for testing)') do |n|
        options[:limit] = n
      end

      opts.on('-v', '--verbose', 'Show formatted LLM output') do
        options[:verbose] = true
      end

      opts.on('--provider PROVIDER', "LLM provider: #{LlmConfig.providers.join(', ')} (default: #{LlmConfig.default_provider})") do |p|
        options[:provider] = p
      end

      defaults = LlmConfig.providers.map { |p| "#{LlmConfig.default_model(:sentence_generation, p)} for #{p}" }
      opts.on('-m', '--model MODEL', "Model (default: #{defaults.join('; ')}; see config/llm-models.yaml)") do |m|
        options[:model] = m
      end

      opts.on('-h', '--help', 'Show this help message') do
        puts opts
        exit
      end

      opts.on('-?', 'Show this help message') do
        puts opts
        exit
      end
    end

    parser.parse!(argv)
    options
  end

  def load_instructions
    if @options[:instructions] && File.exist?(@options[:instructions])
      YamlLoader.load_instructions(@options[:instructions])
    else
      # Use default inline instructions
      default_instructions
    end
  end

  def default_instructions
    <<~INSTRUCTIONS
      You are helping create example sentences for a Japanese language learning Anki deck.

      Given a Japanese vocabulary word with its reading, meaning, and furigana, generate:
      1. A natural, everyday Japanese example sentence using the word
      2. An English translation of the sentence

      Requirements:
      - Use casual/conversational Japanese (appropriate for everyday speech)
      - Keep sentences simple and practical
      - The sentence should clearly demonstrate the word's meaning

      IMPORTANT: Format your response by ending with a line containing only three dashes (---) followed by valid YAML.
      You may include explanatory text before the ---, but everything after --- must be valid YAML.

      Example response format:
      I'll create a sentence for this word.

      ---
      sentence: "日本語の例文"
      sentence_meaning: "English translation"
    INSTRUCTIONS
  end

  def load_existing_output
    IncrementalYamlWriter.load_existing(@options[:output])
  end

  def select_notes_to_process(all_notes, processed_note_ids)
    # Filter out notes that have already been completed successfully
    notes = all_notes.reject { |note| processed_note_ids.include?(note['note_id']) }

    # Apply limit if specified
    if @options[:limit]
      notes.first(@options[:limit])
    else
      notes
    end
  end

  def build_metadata(input_data)
    {
      'target_deck' => input_data.dig('metadata', 'target_deck'),
      'input_file' => @options[:input],
      'generated_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
      'instructions_file' => @options[:instructions],
      'provider' => @options[:provider],
      'model' => @options[:model] || default_model,
      'total_processed' => 0,
      'successful' => 0,
      'failed' => 0
    }
  end

  def build_llm
    model = @options[:model] || default_model
    case @options[:provider]
    when 'claude'
      ClaudeInterface.new(model: model, verbose: @options[:verbose])
    when 'opencode'
      OpenCodeInterface.new(model: model, verbose: @options[:verbose])
    else
      raise ArgumentError, "Unknown provider: #{@options[:provider]}. Use 'claude' or 'opencode'."
    end
  end

  def default_model
    LlmConfig.default_model(:sentence_generation, @options[:provider])
  end

  def print_summary
    puts
    puts "=" * 60
    puts "Generation Summary"
    puts "=" * 60
    puts "Total processed: #{@stats[:total]}"
    puts "Successful: #{@stats[:successful]}"
    puts "Failed: #{@stats[:failed]}"
    puts
    puts "Output saved to: #{@options[:output]}"
    puts "=" * 60
  end

end

# Run the script if executed directly
if __FILE__ == $0
  GenerateSentences.new(ARGV).run
end
