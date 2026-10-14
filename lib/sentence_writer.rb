require 'yaml'
require_relative 'kaishi_fields'
require_relative 'progress_reporter'

class SentenceWriter
  # Tag marking a note whose example sentence was written from generated
  # (LLM-produced) YAML. Applied going forward; existing notes are not backfilled.
  LLM_SENTENCE_TAG = 'generated::llm-sentence'

  attr_reader :stats

  def initialize(yaml_path, options = {})
    @yaml_path = yaml_path
    @dry_run = options[:dry_run] || false
    @only_note_ids = options[:only_note_ids] || []
    @stats = {
      total: 0,
      updated: 0,
      skipped: 0,
      errors: 0
    }
  end

  def load_yaml
    unless File.exist?(@yaml_path)
      raise "Input file not found: #{@yaml_path}"
    end

    YAML.safe_load(File.read(@yaml_path), permitted_classes: [Symbol])
  rescue Psych::SyntaxError => e
    raise "Invalid YAML syntax: #{e.message}"
  end

  def validate_yaml_structure(data)
    unless data.is_a?(Hash)
      ProgressReporter.error("YAML root must be a hash")
      return false
    end

    unless data.key?('notes')
      ProgressReporter.error("YAML missing 'notes' key")
      return false
    end

    unless data['notes'].is_a?(Array)
      ProgressReporter.error("'notes' must be an array")
      return false
    end

    true
  end

  def filter_notes(notes)
    filtered = notes.select do |note|
      # Must have note_id
      next false unless note['note_id']

      # Filter by only_note_ids if specified
      if @only_note_ids.any?
        next false unless @only_note_ids.include?(note['note_id'])
      end

      # Must have successful generation status
      if note['generation_status'] && note['generation_status'] != 'success'
        next false
      end

      # Must have non-empty sentence fields
      next false if note['sentence'].to_s.strip.empty?
      next false if note['sentence_meaning'].to_s.strip.empty?

      true
    end

    @stats[:total] = filtered.size
    filtered
  end

  def validate_note(note)
    errors = []

    errors << "Missing note_id" unless note['note_id']
    errors << "Empty sentence" if note['sentence'].to_s.strip.empty?
    errors << "Empty sentence_meaning" if note['sentence_meaning'].to_s.strip.empty?

    {
      valid: errors.empty?,
      errors: errors
    }
  end

  def dry_run_preview(notes, db)
    puts "DRY RUN MODE - No changes will be made"
    puts ""
    puts "Would update #{notes.size} note(s):"
    puts ""

    notes.each do |note|
      current = db.get_note(note['note_id'])

      if current.nil?
        ProgressReporter.warning("Note #{note['note_id']}: #{note['word']} - NOT FOUND IN DATABASE")
        @stats[:errors] += 1
        next
      end

      puts "Note #{note['note_id']}: #{note['word']}"
      puts "  Word meaning: #{note['word_meaning']}"

      current_sentence = current[:fields][Kaishi::SENTENCE_IDX]
      display_sentence = current_sentence.to_s.empty? ? "(empty)" : current_sentence
      puts "  Current sentence: #{display_sentence}"

      puts "  New sentence:     #{note['sentence']}"
      puts "  New meaning:      #{note['sentence_meaning']}"
      puts "  New furigana:     #{note['sentence_furigana']}"
      puts ""
    end

    puts "Summary:"
    puts "  Would update: #{notes.size - @stats[:errors]} notes"
    puts "  Errors: #{@stats[:errors]} notes"
    puts ""
    puts "Run without --dry-run to apply these changes."
  end

  def write_to_database(notes, db)
    db.transaction do
      notes.each_with_index do |note, index|
        # Validate note
        validation = validate_note(note)
        unless validation[:valid]
          ProgressReporter.warning("Skipping note #{note['note_id']}: #{validation[:errors].join(', ')}")
          @stats[:skipped] += 1
          next
        end

        # Get current note
        current = db.get_note(note['note_id'])
        if current.nil?
          ProgressReporter.warning("Note #{note['note_id']} not found in database")
          @stats[:errors] += 1
          next
        end

        # Update sentence fields
        fields = current[:fields]
        fields[Kaishi::SENTENCE_IDX] = note['sentence']
        fields[Kaishi::SENTENCE_MEANING_IDX] = note['sentence_meaning']
        furigana = note['sentence_furigana'].to_s.strip
        fields[Kaishi::SENTENCE_FURIGANA_IDX] = furigana unless furigana.empty?

        # Write to database
        if db.update_note(note['note_id'], fields)
          db.add_tags(note['note_id'], LLM_SENTENCE_TAG)
          ProgressReporter.progress(index + 1, notes.size, "Updated note #{note['note_id']}: #{note['word']}")
          @stats[:updated] += 1
        else
          ProgressReporter.error("Failed to update note #{note['note_id']}")
          @stats[:errors] += 1
        end
      end
    end
  rescue => e
    ProgressReporter.error("Transaction failed: #{e.message}")
    ProgressReporter.error("All changes have been rolled back")
    raise
  end
end
