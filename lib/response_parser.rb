require 'yaml'

class ResponseParser
  class ParseError < StandardError; end
  class ValidationError < StandardError; end

  # Extract YAML from Claude's response
  # Claude is instructed to output text ending with:
  #   1. A line containing only "---"
  #   2. Valid YAML
  # This method finds the LAST occurrence of "---" and parses everything after it as YAML
  def self.extract_yaml(response_text)
    # Split on lines that contain only "---" (with optional whitespace)
    # The regex /^---\s*$/m matches:
    #   ^ = start of line
    #   --- = three dashes
    #   \s* = optional trailing whitespace
    #   $ = end of line
    #   m = multiline mode
    parts = response_text.split(/^---\s*$/m)

    if parts.length > 1
      # Found at least one "---" separator
      # Take everything after the LAST occurrence
      yaml_text = parts.last.strip
    else
      # No "---" separator found
      # This shouldn't happen if Claude follows instructions, but handle gracefully
      # Try to parse the entire response as YAML
      yaml_text = response_text.strip
    end

    # Remove markdown code fences if Claude included them (shouldn't, but be safe)
    yaml_text = yaml_text.gsub(/^```ya?ml\s*$/im, '')
    yaml_text = yaml_text.gsub(/^```\s*$/m, '')
    yaml_text.strip
  end

  # Parse YAML and validate structure
  def self.parse_sentence_yaml(yaml_text)
    begin
      data = YAML.load(yaml_text)
    rescue Psych::SyntaxError => e
      raise ParseError, "Invalid YAML: #{e.message}"
    end

    validate_sentence_data(data)
    data
  end

  # Validate that the parsed YAML has required fields
  def self.validate_sentence_data(data)
    unless data.is_a?(Hash)
      raise ValidationError, "Expected YAML hash, got #{data.class}"
    end

    required_fields = ['sentence', 'sentence_meaning']
    missing = required_fields - data.keys

    unless missing.empty?
      raise ValidationError, "Missing required fields: #{missing.join(', ')}"
    end

    # Validate non-empty
    required_fields.each do |field|
      value = data[field]
      if value.nil? || value.to_s.strip.empty?
        raise ValidationError, "Field '#{field}' cannot be empty"
      end
    end
  end
end
