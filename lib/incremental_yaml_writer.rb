require 'yaml'
require 'fileutils'

class IncrementalYamlWriter
  def initialize(file_path, metadata)
    @file_path = file_path
    @metadata = metadata
    @notes = []

    # Create output directory if needed
    FileUtils.mkdir_p(File.dirname(@file_path))
  end

  # Add a note to the output
  def add_note(note)
    @notes << note
    save
  end

  # Get current notes (for resume mode)
  def self.load_existing(file_path)
    return [] unless File.exist?(file_path)

    begin
      data = YAML.load_file(file_path)
      data['notes'] || []
    rescue
      []
    end
  end

  # Save the current state to YAML file
  def save
    data = {
      'metadata' => @metadata,
      'notes' => @notes
    }

    File.open(@file_path, 'w') do |file|
      file.write(YAML.dump(data))
    end
  end

  # Update metadata (e.g., increment counters)
  def update_metadata(updates)
    @metadata.merge!(updates)
  end
end
