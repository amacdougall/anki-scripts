require 'yaml'
require 'fileutils'

class YamlWriter
  def self.write_words(file_path, metadata, notes)
    # Ensure output directory exists
    FileUtils.mkdir_p(File.dirname(file_path))

    data = {
      'metadata' => metadata,
      'notes' => notes
    }

    File.open(file_path, 'w') do |file|
      file.write(YAML.dump(data))
    end
  end
end
