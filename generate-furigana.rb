#!/usr/bin/env ruby

require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/mecab_controller'
require_relative 'lib/text_transforms'
require_relative 'lib/card_creator'
require_relative 'lib/jmdict'
require_relative 'lib/word_lookup'
require_relative 'lib/translator_factory'
require_relative 'lib/furigana_reviewer'

# Returns true if the text contains any kanji characters
def contains_kanji?(text)
  DeckStatus.kanji?(text)
end

# Returns true if the text contains <ruby> tags
def contains_ruby?(text)
  text.include?('<ruby>')
end

# Converts <ruby>漢字<rt>かんじ</rt></ruby> to 漢字[かんじ]
def ruby_to_bracket(text)
  text.gsub(/<ruby>([^<]+)<rt>([^<]+)<\/rt><\/ruby>/, '\1[\2]')
end

# The JMdict entry best matching a word (and, when given, the note's reading),
# or nil when the word isn't in the dictionary. Used to detect words that are
# usually written in kana alone.
def jmdict_entry_for(word, reading = '')
  WordLookup.entry_for(CardCreator.strip_ruby_tags(word), reading.strip)
end

REVIEWED_TAG = DeckStatus::FURIGANA_REVIEWED_TAG

# Sentences per review request. Small enough to keep each response short and
# easy for the model to get right.
REVIEW_BATCH_SIZE = 20

# Review batches sent at once. Each is a separate LLM CLI process, so this only
# caps in-flight requests; lower it if the provider starts rejecting them.
DEFAULT_REVIEW_JOBS = 4

# Field indices for furigana (Kaishi 1.5k format)
WORD_FURIGANA_IDX = Kaishi::WORD_FURIGANA_IDX
SENTENCE_FURIGANA_IDX = Kaishi::SENTENCE_FURIGANA_IDX

cli = ScriptCLI.new(
  'generate-furigana.rb',
  'Generates furigana in bracket notation with MeCab, then has an LLM review the',
  'sentence readings in context (with JMdict readings and the deck\'s name readings as hints).'
)
options = cli.options
options.merge!(review: true, review_unreviewed: false, review_jobs: DEFAULT_REVIEW_JOBS)
cli.dry_run
cli.limit
cli.force('Overwrite existing furigana data (and review it again)')
cli.on("--[no-]review", "AI review of sentence furigana generated this run (default: on)") do |v|
  options[:review] = v
end
cli.on("--review-unreviewed", "Skip generation; review sentence furigana not yet tagged #{REVIEWED_TAG} " \
                              "(resumes a review stopped by a usage limit or failure)") do
  options[:review_unreviewed] = true
end
# On 80 test sentences (7 errors of 5 kinds) Sonnet caught all 5 kinds;
# deepseek-v4.1-flash and glm-5.3-flash each caught 3, different ones, with no
# wrong changes. OpenCode suits large batches that would spend Claude usage.
cli.llm(:furigana_review, providers: %w[claude opencode], help: 'LLM for the review')
cli.on("--review-jobs N", Integer, "Review batches sent at once (default: #{DEFAULT_REVIEW_JOBS})") do |n|
  options[:review_jobs] = [n, 1].max
end
cli.parse!

if options[:review_unreviewed] && (options[:force] || !options[:review])
  cli.usage_error("--review-unreviewed can't be combined with --force or --no-review")
end

db = cli.connect!

# Check MeCab availability
begin
  puts "Checking MeCab availability..."
  unless MecabController.available?
    ProgressReporter.error("MeCab support files not found in Anki plugin directory")
    puts "Expected location: #{MecabController::MECAB_SUPPORT_DIR}"
    puts "Please ensure the Japanese Furigana plugin is installed in Anki."
    exit ScriptCLI::EXIT_ERROR
  end

  mecab = MecabController.new
  ProgressReporter.success("MeCab is available")
  puts ""
rescue => e
  ProgressReporter.error("Failed to initialize MeCab: #{e.message}")
  exit ScriptCLI::EXIT_ERROR
end

reviewer_llm = nil
if options[:review] && !options[:dry_run]
  begin
    reviewer_llm = TranslatorFactory.llm(options[:provider], options[:model], task: :furigana_review)
  rescue TranslatorFactory::UnknownProviderError, LLMInterface::NotFoundError => e
    ProgressReporter.error("Can't set up the furigana review: #{e.message}")
    exit ScriptCLI::EXIT_ERROR
  end
end

# Ensure the local JMdict dataset is present/current up front (used to detect
# words usually written in kana alone). Downloads on first run; a monthly-ish
# update check runs here rather than mid-processing.
JMDict.ensure_current!

begin
  # Each note carries its deck name (a subdeck's, for notes in one) so the
  # right deck's TextTransforms fire. A note can technically have cards in
  # multiple decks, but for our note type that's a non-case — pick the first
  # card's deck.
  all_notes = cli.notes(db, with_deck: true)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")
  puts ""

  # Filter notes that need processing (none when only reviewing)
  notes_to_process = options[:review_unreviewed] ? [] : all_notes.select do |note|
    options[:force] || DeckStatus.needs_furigana?(note)
  end

  # Apply limit if specified
  if options[:limit]
    notes_to_process = notes_to_process.take(options[:limit])
  end

  # Notes whose sentence furigana goes to the AI review. Normally filled during
  # generation below with the notes whose sentence furigana was written this
  # run; with --review-unreviewed, every note in scope not yet tagged reviewed.
  review_notes = []
  if options[:review_unreviewed]
    review_notes = all_notes.select { |note| DeckStatus.needs_furigana_review?(note) }
    review_notes = review_notes.take(options[:limit]) if options[:limit]
    puts "Unreviewed sentence furigana: #{review_notes.size} notes"
  else
    puts "Notes to process: #{notes_to_process.size}"
  end
  puts ""

  if notes_to_process.empty? && review_notes.empty?
    puts "No notes to process!"
    puts ""
    if !options[:force] && !options[:review_unreviewed]
      puts "Note: Use --force to regenerate existing furigana data"
    end
    exit ScriptCLI::EXIT_OK
  end

  # Statistics
  stats = {
    total: notes_to_process.size,
    word_furigana_added: 0,
    sentence_furigana_added: 0,
    skipped: 0,
    updated: 0,
    errors: 0,
    reviewed: 0,
    review_corrected: 0,
    review_rejected: 0,
    review_failed: 0
  }

  # Process notes
  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  db.transaction do
    notes_to_process.each_with_index do |note, idx|
      note_id = note[:id]
      fields = note[:fields]

      # Extract word, reading, and sentence. The word field has its own reading
      # field, so MeCab's preferred_reading path handles non-standard readings
      # without TextTransforms. The sentence field needs deck-specific transforms
      # since names appearing inline have no per-note reading hint.
      word = fields[Kaishi::WORD_IDX] || ''
      word_reading = fields[Kaishi::WORD_READING_IDX] || ''
      sentence = fields[Kaishi::SENTENCE_IDX] || ''
      sentence_for_mecab, sentence_restore = TextTransforms.apply_furigana(sentence, note[:deck])
      word_furigana = fields[WORD_FURIGANA_IDX] || ''
      sentence_furigana = fields[SENTENCE_FURIGANA_IDX] || ''

      # Track what we're updating
      updated_fields = []
      sentence_generated = false
      word_has_furigana = word_furigana.include?('[')
      sentence_has_furigana = sentence_furigana.include?('[')

      begin
        # When the word is usually written in kana alone but contains kanji,
        # rewrite the Word field itself with <ruby> furigana so the card shows
        # the kana form prominently while preserving the kanji. This mirrors
        # add-cards.rb, applied here to notes added by other mechanisms. The
        # word-furigana logic below then flows through the contains_ruby? branch.
        if contains_kanji?(word) && !contains_ruby?(word)
          entry = jmdict_entry_for(word, word_reading)
          if entry && WordLookup.usually_kana?(entry)
            ruby_reading = word_reading.strip.empty? ? (WordLookup.extract_reading(entry) || '') : word_reading
            unless ruby_reading.strip.empty?
              bracket = mecab.generate_furigana(word, preferred_reading: ruby_reading)
              unless bracket.strip.empty?
                ruby_word = CardCreator.bracket_to_ruby(bracket)
                if ruby_word != word
                  fields[Kaishi::WORD_IDX] = ruby_word
                  word = ruby_word
                  updated_fields << "word (ruby kana)"
                end
              end
            end
          end
        end

        # If word furigana field is empty, seed it from the word field
        if word_furigana.strip.empty? && !word.strip.empty?
          fields[WORD_FURIGANA_IDX] = word
          word_furigana = word
          updated_fields << "word (seeded)"
        end

        # If sentence furigana field is empty, seed it from the sentence field
        if sentence_furigana.strip.empty? && !sentence.strip.empty?
          fields[SENTENCE_FURIGANA_IDX] = sentence
          sentence_furigana = sentence
          updated_fields << "sentence (seeded)"
        end

        # Generate word furigana if needed
        if (!word_has_furigana || options[:force]) && contains_ruby?(word)
          # Convert ruby tags to bracket notation directly. Checked before the
          # MeCab branch so --force never feeds the <ruby> HTML to MeCab.
          fields[WORD_FURIGANA_IDX] = ruby_to_bracket(word)
          updated_fields << "word (ruby)"
          stats[:word_furigana_added] += 1
        elsif (!word_has_furigana && contains_kanji?(word)) || options[:force]
          if !word.strip.empty?
            # When a reading is available, use it to generate furigana with
            # the correct reading rather than relying on MeCab's default.
            generated_word_furigana = if !word_reading.strip.empty?
              mecab.generate_furigana(word, preferred_reading: word_reading)
            else
              mecab.generate_furigana(word)
            end
            if !generated_word_furigana.strip.empty?
              fields[WORD_FURIGANA_IDX] = generated_word_furigana
              updated_fields << "word"
              stats[:word_furigana_added] += 1
            end
          end
        end

        # Generate sentence furigana if needed
        if (!sentence_has_furigana && contains_kanji?(sentence)) || options[:force]
          if !sentence.strip.empty?
            generated_sentence_furigana = sentence_restore.call(mecab.generate_furigana(sentence_for_mecab))
            if !generated_sentence_furigana.strip.empty?
              fields[SENTENCE_FURIGANA_IDX] = generated_sentence_furigana
              updated_fields << "sentence"
              sentence_generated = true
              stats[:sentence_furigana_added] += 1
            end
          end
        end

        # Skip if nothing to update
        if updated_fields.empty?
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} ⊘ Skipped (no changes)")
          stats[:skipped] += 1
          next
        end

        # Update note
        if options[:dry_run]
          ProgressReporter.progress(idx + 1, stats[:total], "#{word} ✓ Would update: #{updated_fields.join(', ')} [DRY RUN]")
          review_notes << note if sentence_generated
        else
          begin
            db.update_note!(note_id, fields)
            ProgressReporter.progress(idx + 1, stats[:total], "#{word} ✓ Updated: #{updated_fields.join(', ')}")
            stats[:updated] += 1
            review_notes << note if sentence_generated
          rescue AnkiConnect::Error => e
            ProgressReporter.progress(idx + 1, stats[:total], "#{word} ✗ Update failed: #{e.message[0, 300]}")
            stats[:errors] += 1
          end
        end

      rescue => e
        ProgressReporter.progress(idx + 1, stats[:total], "#{word} ✗ Error: #{e.message}")
        stats[:errors] += 1
      end
    end
  end

  # AI review of the sentence furigana generated above (review_notes share
  # their fields arrays with the notes just written).
  #
  # Several words are often mined from one sentence, so notes are grouped by
  # deck + current furigana and each unique sentence is reviewed once; its
  # result applies to every note in the group. (Deck is part of the key because
  # each deck has its own fixed readings; furigana rather than sentence text,
  # so a hand-edited copy is reviewed on its own.) Batches of unique sentences
  # then go out --review-jobs at a time. Workers only call the LLM; the main
  # thread applies corrections, writes notes and tags them.
  if options[:review] && !review_notes.empty?
    puts ""
    groups = review_notes.each_with_object({}) do |note, acc|
      furigana = note[:fields][SENTENCE_FURIGANA_IDX].to_s
      next unless furigana.include?('[')

      (acc[[note[:deck], furigana]] ||= []) << note
    end

    if options[:dry_run]
      puts "Would review #{groups.size} unique sentences (#{review_notes.size} notes) " \
           "with #{options[:provider]} [DRY RUN]"
    else
      model_name = options[:model]
      puts "Reviewing #{groups.size} unique sentences (#{review_notes.size} notes) with " \
           "#{options[:provider]} (#{model_name}), #{options[:review_jobs]} batches at a time:"
      db.remove_tags(review_notes.map { |note| note[:id] }, REVIEWED_TAG)

      batches = groups.keys.group_by(&:first).flat_map do |deck, keys|
        keys.each_slice(REVIEW_BATCH_SIZE).map { |slice| [deck, slice] }
      end
      queue = Queue.new
      batches.each { |batch| queue << batch }
      results = Queue.new

      # Set by a worker that hits the provider's usage limit (e.g. a spent Claude
      # session): the others finish their in-flight batch and take no more.
      usage_limit_hit = false

      review_started = Time.now
      worker_count = [options[:review_jobs], batches.size].min
      workers = Array.new(worker_count) do
        Thread.new do
          loop do
            break if usage_limit_hit

            deck, keys = begin
              queue.pop(true)
            rescue ThreadError
              break # queue drained
            end

            # Item ids are positions in the batch; keys[id] maps back to a group.
            items = keys.each_with_index.map do |key, i|
              { id: i, sentence: groups[key].first[:fields][Kaishi::SENTENCE_IDX].to_s, furigana: key[1] }
            end
            reviewer = FuriganaReviewer.new(llm: reviewer_llm, transforms: TextTransforms::DECK_TEXT_TRANSFORMS[deck], mecab: mecab)
            begin
              results << [keys, reviewer.review(items), nil]
            rescue FuriganaReviewer::ReviewError => e
              results << [keys, nil, e]
            rescue LLMInterface::UsageLimitError => e
              usage_limit_hit = true
              results << [keys, nil, e]
            end
          end
        ensure
          results << :done
        end
      end

      finished_workers = 0
      reviewed_sentences = 0
      usage_limit_error = nil
      while finished_workers < worker_count
        item = results.pop
        if item == :done
          finished_workers += 1
          next
        end

        keys, result, error = item
        if error
          failed_notes = keys.sum { |key| groups[key].size }
          stats[:review_failed] += failed_notes
          if error.is_a?(LLMInterface::UsageLimitError)
            puts "  ✗ Usage limit reached: #{error.message[0, 200]}" unless usage_limit_error
            usage_limit_error = error
          else
            puts "  ✗ Review failed for #{keys.size} sentences (#{failed_notes} notes): #{error.message[0, 200]}"
          end
          next
        end

        rejected = result[:rejected].to_h { |id, reason, proposed| [id, [reason, proposed]] }
        reviewed_ids = []
        keys.each_with_index do |key, i|
          notes = groups[key]
          sentence = notes.first[:fields][Kaishi::SENTENCE_IDX]
          if rejected.key?(i)
            # Keep the original furigana but count the sentence as reviewed, so
            # it isn't sent back on every run; the proposal is printed for a
            # hand edit.
            reason, proposed = rejected[i]
            puts "  ✗ Rejected correction for #{sentence}: #{reason}"
            puts "      proposed: #{proposed}"
            puts "      kept the original and marked it reviewed (note #{notes.map { |note| note[:id] }.join(', ')}); edit by hand if needed"
            stats[:review_rejected] += 1
            reviewed_ids.concat(notes.map { |note| note[:id] })
            next
          end

          corrected = result[:corrections][i]
          unless corrected
            reviewed_ids.concat(notes.map { |note| note[:id] })
            next
          end

          updated = notes.select do |note|
            note[:fields][SENTENCE_FURIGANA_IDX] = corrected
            db.update_note!(note[:id], note[:fields])
            true
          rescue AnkiConnect::Error => e
            puts "  ✗ Failed to update note #{note[:id]}: #{e.message[0, 300]}"
            stats[:errors] += 1
            false
          end
          reviewed_ids.concat(updated.map { |note| note[:id] })

          old_tokens = key[1].split(' ')
          new_tokens = corrected.split(' ')
          copies = notes.size > 1 ? " (#{updated.size} of #{notes.size} notes)" : ''
          puts "  ✓ #{sentence}#{copies}"
          puts "      #{(old_tokens - new_tokens).join(' ')}  →  #{(new_tokens - old_tokens).join(' ')}"
          stats[:review_corrected] += 1
        end

        db.add_tags(reviewed_ids, REVIEWED_TAG) unless reviewed_ids.empty?
        stats[:reviewed] += reviewed_ids.size
        reviewed_sentences += keys.size
        puts "  … #{reviewed_sentences} of #{groups.size} sentences reviewed (#{(Time.now - review_started).round}s)"
      end
      workers.each(&:join)

      # Batches no worker got to before the limit stopped them.
      until queue.empty?
        _deck, keys = queue.pop
        stats[:review_failed] += keys.sum { |key| groups[key].size }
      end

      if usage_limit_error
        resume = ['./generate-furigana.rb']
        resume += ['--target-deck', "'#{options[:target_deck]}'"]
        resume += ['--review-unreviewed', '--provider', options[:provider]]
        resume += ['--model', options[:model]]
        puts ""
        ProgressReporter.error("Stopped the review: #{options[:provider]} usage limit reached. " \
                               "#{stats[:review_failed]} notes are still unreviewed (untagged).")
        puts "Resume once the limit resets with:"
        puts "  #{resume.join(' ')}"
      end
    end
  end

  # Display summary
  puts ""
  puts "=" * 70
  puts "SUMMARY"
  puts "=" * 70
  puts "  Total notes:              #{stats[:total]}"
  puts "  Word furigana added:      #{stats[:word_furigana_added]}"
  puts "  Sentence furigana added:  #{stats[:sentence_furigana_added]}"
  puts "  Skipped:                  #{stats[:skipped]}"
  puts "  Updated:                  #{stats[:updated]}" unless options[:dry_run]
  puts "  Errors:                   #{stats[:errors]}"
  if options[:review] && !options[:dry_run]
    puts "  Notes reviewed:           #{stats[:reviewed]}"
    puts "  Sentences corrected:      #{stats[:review_corrected]}"
    puts "  Rejected corrections:     #{stats[:review_rejected]}"
    puts "  Notes failed in review:   #{stats[:review_failed]}"
  end
  puts "=" * 70
  puts ""

  if options[:dry_run]
    puts "This was a dry run. No changes were made to the database."
    puts "Run without --dry-run to apply changes."
  elsif stats[:updated] > 0
    ProgressReporter.success("Successfully updated #{stats[:updated]} notes!")
  end

  exit ScriptCLI::EXIT_LIMIT if usage_limit_error
  exit(stats[:errors] + stats[:review_failed] > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
