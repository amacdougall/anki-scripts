# frozen_string_literal: true

require 'yaml'
require_relative 'llm_interface'
require_relative 'response_parser'
require_relative 'text_transforms'

# Translates Japanese text to English via an LLM CLI (Claude or OpenCode), for
# use when Google Translate's free endpoint is unavailable or rate-limited.
# Implements the same interface as GoogleTranslationProvider.
class LlmTranslationProvider
  class TranslationError < StandardError; end

  MAX_RETRIES = 3
  RETRY_DELAY = 2
  TRANSLATION_PROMPTS_DIR = File.expand_path('../prompts/translation', __dir__)

  # transforms is an optional { kanji => 'kanji[reading]' } hash (see
  # TextTransforms::DECK_TEXT_TRANSFORMS) for the deck being translated. When
  # given, its readings are passed to the LLM as hints so it doesn't guess a
  # character name's reading from the kanji alone. Not every deck has one.
  #
  # deck_name, when given, pulls in prompts/translation/<deck_name>.md (if it
  # exists) as a sentence-translation addendum: character genders, source
  # material context, or anything else that helps the LLM choose pronouns and
  # other grammar English requires but Japanese omits.
  def initialize(llm:, transforms: nil, deck_name: nil)
    @llm = llm
    @transforms = transforms
    @deck_name = deck_name
  end

  # @return [String] the English translation
  def translate(text)
    fetch(build_translate_prompt(text)) do |data|
      require_translation!(data)
    end
  end

  # @return [Hash] { translation: String, romaji: String|nil }
  def translate_with_reading(text)
    fetch(build_reading_prompt(text)) do |data|
      { translation: require_translation!(data), romaji: data['romaji'] }
    end
  end

  private

  # Sends prompt to the LLM, extracts and parses its YAML-fenced response, and
  # yields the parsed Hash to build the return value. Retries on API failure,
  # bad YAML, or a block-raised TranslationError (e.g. a missing field).
  def fetch(prompt)
    attempt = 0
    last_error = nil

    while attempt < MAX_RETRIES
      attempt += 1

      begin
        response = @llm.generate(prompt)
        yaml_text = ResponseParser.extract_yaml(response)
        data = YAML.load(yaml_text)

        unless data.is_a?(Hash)
          raise TranslationError, "Expected YAML hash, got #{data.class}"
        end

        return yield(data)

      rescue LLMInterface::APIError, Psych::SyntaxError, TranslationError => e
        last_error = e
        sleep(RETRY_DELAY * attempt) if attempt < MAX_RETRIES
      end
    end

    raise TranslationError, "Failed after #{MAX_RETRIES} attempts: #{last_error.message}"
  end

  def require_translation!(data)
    translation = data['translation']
    if translation.nil? || translation.to_s.strip.empty?
      raise TranslationError, "Missing or empty 'translation' field in response"
    end
    translation
  end

  def build_translate_prompt(text)
    <<~PROMPT
      Translate the following Japanese sentence into natural, idiomatic English.
      #{reading_hints}#{deck_addendum}
      IMPORTANT: Format your response by ending with a line containing only three
      dashes (---) followed by valid YAML with a single "translation" key.
      You may include explanatory text before the ---, but everything after ---
      must be valid YAML.

      Example response format:
      ---
      translation: "This is an example translation."

      Japanese sentence: #{text}
    PROMPT
  end

  def build_reading_prompt(text)
    <<~PROMPT
      Provide an English meaning and the Hepburn romanization for the following
      Japanese word.
      #{reading_hints}
      IMPORTANT: Format your response by ending with a line containing only three
      dashes (---) followed by valid YAML with "translation" and "romaji" keys.
      You may include explanatory text before the ---, but everything after ---
      must be valid YAML.

      Example response format:
      ---
      translation: "to eat"
      romaji: "taberu"

      Japanese word: #{text}
    PROMPT
  end

  # Formats @transforms as reading hints for the prompt, e.g.
  # "Note: 水月 is read みずき (not its default reading)." Returns '' when no
  # transforms were configured for this deck.
  def reading_hints
    return '' if @transforms.nil? || @transforms.empty?

    lines = @transforms.map do |kanji, bracket_form|
      "  #{kanji} is read #{TextTransforms.extract_reading(bracket_form)}"
    end

    <<~HINTS

      Note: Use the following readings, even if they\'re nonstandard; e.g. names.

      #{lines.join("\n")}

    HINTS
  end

  # Contents of prompts/translation/<deck_name>.md, or '' when no deck was
  # given or the deck has no addendum.
  def deck_addendum
    return '' if @deck_name.nil? || @deck_name.include?('/')

    path = File.join(TRANSLATION_PROMPTS_DIR, "#{@deck_name}.md")
    return '' unless File.file?(path)

    "\n#{File.read(path).strip}\n\n"
  end
end
