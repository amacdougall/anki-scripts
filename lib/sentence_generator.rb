require_relative 'llm_interface'
require_relative 'response_parser'

class SentenceGenerator
  class GenerationError < StandardError; end

  MAX_RETRIES = 3
  RETRY_DELAY = 2

  def initialize(instructions, llm:, verbose: false)
    @instructions = instructions
    @llm = llm
  end

  # Generate sentences for a single note
  # Returns hash with sentence fields or raises error
  def generate_for_note(note)
    prompt = build_prompt(note)

    attempt = 0
    last_error = nil

    while attempt < MAX_RETRIES
      attempt += 1

      begin
        # Call Claude CLI
        response = @llm.generate(prompt)

        # Extract and parse YAML
        yaml_text = ResponseParser.extract_yaml(response)
        sentence_data = ResponseParser.parse_sentence_yaml(yaml_text)

        return sentence_data

      rescue LLMInterface::APIError,
             ResponseParser::ParseError,
             ResponseParser::ValidationError => e
        last_error = e

        if attempt < MAX_RETRIES
          sleep(RETRY_DELAY * attempt) # Exponential backoff
          next
        end
      end
    end

    # All retries failed
    raise GenerationError, "Failed after #{MAX_RETRIES} attempts: #{last_error.message}"
  end

  private

  def build_prompt(note)
    word_context = <<~CONTEXT
      Word: #{note['word']}
      Reading: #{note['word_reading'].to_s.empty? ? '(not provided)' : note['word_reading']}
      Meaning: #{note['word_meaning']}
      Sentence Concept: #{note['sentence_concept'].to_s.empty? ? '(not provided)' : note['sentence_concept']}
    CONTEXT

    "#{@instructions}\n\n#{word_context}"
  end
end
