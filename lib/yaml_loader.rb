require 'yaml'

class YamlLoader
  def self.load_words(file_path)
    raise "File not found: #{file_path}" unless File.exist?(file_path)

    begin
      YAML.load_file(file_path)
    rescue Psych::SyntaxError => e
      raise "Invalid YAML format in #{file_path}: #{e.message}"
    end
  end

  def self.load_instructions(file_path)
    return nil unless file_path
    raise "Instructions file not found: #{file_path}" unless File.exist?(file_path)

    File.read(file_path)
  end
end
