#!/usr/bin/env ruby

require 'net/http'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/gemini_setup'
require_relative 'lib/script_cli'
require_relative 'lib/deck_status'
require_relative 'lib/text_transforms'
require_relative 'lib/tts_text'
require_relative 'lib/reading_check'

# Anki field indices (Kaishi 1.5k note type)
WORD_AUDIO_IDX     = Kaishi::WORD_AUDIO_IDX
SENTENCE_AUDIO_IDX = Kaishi::SENTENCE_AUDIO_IDX

# Lite: ~1/3 cheaper than gemini-3.8-flash-tts, with no audible difference that
# matters for flashcards (2026-09-26 audition).
DEFAULT_MODEL = 'gemini-3.8-flash-lite-tts'

# Resume markers. Every clip this run will generate gets its note tagged first;
# the tag comes off once the clip is written. Notes still tagged (after an abort,
# a failure or Ctrl-C) are picked up by the next run even without --force.
PENDING_TAGS = DeckStatus::AUDIO_PENDING_TAGS

# Concurrent Whisper transcriptions for the reading check. Each loads the model
# (~1.6 GB) and uses the GPU, so this stays well below --jobs.
DEFAULT_WHISPER_JOBS = 2

# Clips generated concurrently. The work is I/O-bound (waiting on Gemini), so
# this only caps in-flight requests; lower it with --jobs if Gemini starts
# returning 429s.
DEFAULT_JOBS = 8

# Voice pools — Gemini catalogue voices with accent "Tokyo Japanese", chosen by
# audition. Regional voices would teach regional pitch accent, so keep these to
# Tokyo voices only.
FEMALE_VOICES = %w[
  ja-jp-advisor-12
  ja-jp-concierge-7
  ja-jp-csagent-4
  ja-jp-podcaster-2
  ja-jp-storyteller-1
  ja-jp-techagent-7
  ja-jp-training-1
  ja-jp-tutor-1
].freeze

MALE_VOICES = %w[
  ja-jp-advisor-3
  ja-jp-advisor-8
  ja-jp-csagent-7
  ja-jp-podcaster-1
  ja-jp-storyteller-5
  ja-jp-training-4
  ja-jp-tutor-4
  ja-jp-tutor-9
].freeze

VOICES = (MALE_VOICES + FEMALE_VOICES).freeze

# Delivery phrases, one picked at random per clip and slotted into the sentence
# and word styles below. Aim for normal-speed speech (for listening practice):
# "slowly" or "for a language learner" noticeably slows delivery (2026-09-26:
# a 24-character sentence took ~6.8s with "slowly and clearly, for a language
# learner" vs ~4.1–5.0s with these). Edit or extend freely.
DELIVERY_PHRASES = [
  'clearly, at a natural conversational pace',
  'at a normal speaking pace, articulating clearly like a news announcer',
].freeze

# On 3.8 models, style is sent as delivery direction (speechMetadata.style) and
# never spoken; the text itself is read verbatim.
def sentence_style
  "Speaking precise 標準語 #{DELIVERY_PHRASES.sample}."
end

# Words are generated in isolation, with the card's kana reading appended to the
# style as a reading instruction. Verified 2026-09-26 on ambiguous words
# (市場 いちば/しじょう, 生物 なまもの, 上手 うわて, 一日 ついたち): the model followed
# the instructed reading every time. Experimental; revisit if readings drift.
def word_style(reading)
  style = "Demonstrating precise 標準語 pronunciation of an individual word, #{DELIVERY_PHRASES.sample}."
  reading.empty? ? style : "#{style} Read it as 「#{reading}」."
end

# ---

cli = ScriptCLI.new(
  'generate-gemini-audio.rb',
  'Generates Japanese word and sentence audio via Gemini TTS for cards missing it.'
)
options = cli.options
options.merge!(word_only: false, sentence_only: false, word_ruby_only: false, model: DEFAULT_MODEL,
               jobs: DEFAULT_JOBS, voicevox_fallback: true, reading_check: true,
               whisper_jobs: DEFAULT_WHISPER_JOBS, check_existing: false)
cli.dry_run('Preview without calling Gemini or modifying Anki')
cli.limit
cli.force('Regenerate audio even if already present')
cli.on("--word-only", "Only generate word audio (field #{WORD_AUDIO_IDX})") do
  options[:word_only] = true
end
cli.on("--sentence-only", "Only generate sentence audio (field #{SENTENCE_AUDIO_IDX})") do
  options[:sentence_only] = true
end
cli.on("--word-ruby-only", "Regenerate word audio only for words with <ruby> furigana, using the ruby reading for TTS") do
  options[:word_ruby_only] = true
  options[:word_only]      = true
  options[:force]          = true
end
cli.on("--model MODEL", "Gemini TTS model (default: #{DEFAULT_MODEL})") do |m|
  options[:model] = m
end
cli.on("--jobs N", Integer, "Clips to generate concurrently (default: #{DEFAULT_JOBS})") do |n|
  options[:jobs] = [n, 1].max
end
cli.on("--[no-]voicevox-fallback", "Regenerate clips Gemini's content filter blocks with generate-voicevox-audio.rb (default: on; skipped if no VOICEVOX server is running)") do |v|
  options[:voicevox_fallback] = v
end
cli.on("--[no-]reading-check", "Transcribe each clip with Whisper and retry misread words in kana (default: on)") do |v|
  options[:reading_check] = v
end
cli.on("--check-existing", "Run the reading check on existing audio instead of generating; regenerate (in kana) only clips that fail") do
  options[:check_existing] = true
end
cli.on("--whisper-jobs N", Integer, "Concurrent Whisper transcriptions (default: #{DEFAULT_WHISPER_JOBS})") do |n|
  options[:whisper_jobs] = [n, 1].max
end
cli.parse!

# ---

include TtsText

# Select a voice from the pool matching the note's voice gender preference
# (see TtsText.voice_gender). Returns a Gemini voice ID.
def select_voice(note)
  case TtsText.voice_gender(note)
  when 'female' then FEMALE_VOICES.sample
  when 'male'   then MALE_VOICES.sample
  else               VOICES.sample
  end
end

# Media filename referenced by an audio field ("[sound:x.wav]" => "x.wav").
def sound_file(field)
  field[/\[sound:([^\]]+)\]/, 1]
end

# Voice ID encoded in one of our filenames (gemini_<note>_<kind>_<voice>.wav,
# optionally with a _kana suffix), or nil for other files (e.g. VOICEVOX).
def voice_from_filename(filename)
  filename.to_s[/\Agemini_\d+_(?:word|sent)_(.+?)(?:_kana)?\.wav\z/, 1]
end

def truncate(text, n = 50)
  "#{text[0, n]}#{'...' if text.length > n}"
end

# Same server address generate-voicevox-audio.rb uses.
def voicevox_url
  ENV.fetch('VOICEVOX_URL', 'http://127.0.0.1:50021').chomp('/')
end

def voicevox_running?
  Net::HTTP.get_response(URI("#{voicevox_url}/version")).is_a?(Net::HTTPSuccess)
rescue StandardError
  false
end

# ---

if VOICES.empty?
  ProgressReporter.error("No voices configured: fill in FEMALE_VOICES / MALE_VOICES")
  exit ScriptCLI::EXIT_ERROR
end

if options[:check_existing] && (!options[:reading_check] || options[:force])
  cli.usage_error("--check-existing can't be combined with --no-reading-check or --force")
end

db = cli.connect!

puts "Using Gemini model #{options[:model]}"
if options[:reading_check] && !options[:dry_run]
  if ReadingCheck.available?
    puts "Reading check on (Whisper, #{options[:whisper_jobs]} at a time)"
  elsif options[:check_existing]
    ProgressReporter.error("--check-existing needs Whisper; run ./setup-whisper.sh first")
    exit ScriptCLI::EXIT_ERROR
  else
    puts "Reading check skipped: Whisper isn't set up (run ./setup-whisper.sh to enable it)"
    options[:reading_check] = false
  end
end
puts ""

begin
  # Each note carries its deck name (a subdeck's, for notes in one) so the
  # right deck's TextTransforms fire.
  all_notes = cli.notes(db, with_deck: true)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")
  puts ""

  notes_to_process = all_notes.select do |note|
    f = note[:fields]
    word = f[Kaishi::WORD_IDX].to_s.strip
    sent = f[Kaishi::SENTENCE_IDX].to_s.strip
    w_audio = f[WORD_AUDIO_IDX].to_s.strip
    s_audio = f[SENTENCE_AUDIO_IDX].to_s.strip

    # --check-existing targets clips that have audio; otherwise, clips that are
    # forced, missing, or tagged pending.
    if options[:check_existing]
      needs_word = !options[:sentence_only] && !word.empty? && w_audio.include?('[sound:')
      needs_sent = !options[:word_only] && !sent.empty? && s_audio.include?('[sound:')
    else
      needs_word = !options[:sentence_only] &&
                   (options[:force] ? !word.empty? : DeckStatus.needs_word_audio?(note))
      needs_sent = !options[:word_only] &&
                   (options[:force] ? !sent.empty? : DeckStatus.needs_sentence_audio?(note))
    end
    needs_word &&= word.include?('<ruby>') if options[:word_ruby_only]

    note[:needs] = { 'word' => needs_word, 'sent' => needs_sent }
    needs_word || needs_sent
  end

  notes_to_process = notes_to_process.take(options[:limit]) if options[:limit]

  resumed = notes_to_process.count { |note| (note[:tags] || []).any? { |t| PENDING_TAGS.value?(t) } }
  puts "Notes to process: #{notes_to_process.size}"
  puts "  (#{resumed} still tagged audio::pending from an earlier run)" if resumed > 0
  puts ""

  # Tag this run's targets up front, so an interrupted run can resume. Not in
  # --check-existing: the tag means "regenerate", and re-running a check is cheap.
  unless options[:dry_run] || options[:check_existing]
    PENDING_TAGS.each do |kind, tag|
      ids = notes_to_process.select { |note| note[:needs][kind] }.map { |note| note[:id] }
      db.add_tags(ids, tag) unless ids.empty?
    end
  end

  if notes_to_process.empty?
    puts "No notes need audio generation."
    puts "Use --force to regenerate existing audio." unless options[:force]
    exit ScriptCLI::EXIT_OK
  end

  stats = {
    total:            notes_to_process.size,
    word_generated:   0,
    sent_generated:   0,
    skipped_existing: 0,
    skipped_empty:    0,
    error_blocked:    0,
    blocked_fallback: 0,
    error_no_audio:   0,
    error_api:        0,
    error_network:    0,
    error_update:     0,
    check_ok:         0,
    check_retried:    0,
    kept_existing:    0,
    check_skipped:    0,
    cost:             0.0
  }

  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  # Phase 1 (main thread): decide what each note needs, building one job per
  # clip. The voice is chosen per note, so a note's word and sentence share it.
  jobs  = []
  notes = {} # note_id => { fields:, pending:, updated: }

  notes_to_process.each_with_index do |note, idx|
    note_id    = note[:id]
    fields     = note[:fields]
    voice      = select_voice(note)
    note_jobs  = []

    word    = fields[Kaishi::WORD_IDX].to_s
    sent    = fields[Kaishi::SENTENCE_IDX].to_s
    w_audio = fields[WORD_AUDIO_IDX].to_s.strip
    s_audio = fields[SENTENCE_AUDIO_IDX].to_s.strip

    prefix = "[#{idx + 1}/#{stats[:total]}]"

    # -- Word audio --
    if !note[:needs]['word']
      stats[:skipped_existing] += 1 unless options[:sentence_only] || w_audio.empty?
    else
      word_text = TextTransforms.apply_reading(word_tts_text(word), note[:deck])
      reading   = strip_html(fields[Kaishi::WORD_READING_IDX].to_s)
      if word_text.empty?
        puts "#{prefix} [note #{note_id}] word text empty after stripping — skipping"
        stats[:skipped_empty] += 1
        db.remove_tags(note_id, PENDING_TAGS['word']) unless options[:dry_run]
      elsif options[:dry_run]
        action = options[:check_existing] ? "would check #{sound_file(w_audio)}" : "would generate word audio (#{voice})"
        puts "#{prefix} #{word_text} (#{reading}) — #{action} [DRY RUN]"
        stats[:word_generated] += 1 unless options[:check_existing]
      else
        existing = sound_file(w_audio) if options[:check_existing]
        note_jobs << { note_id: note_id, kind: 'word', field_idx: WORD_AUDIO_IDX,
                       voice: voice_from_filename(existing) || voice, existing_file: existing,
                       text: word_text, style: word_style(reading),
                       reading: (reading unless reading.empty?),
                       label: "#{prefix} #{word_text} (#{reading})" }
      end
    end

    # -- Sentence audio --
    if !note[:needs]['sent']
      stats[:skipped_existing] += 1 unless options[:word_only] || s_audio.empty?
    else
      sent_text = TextTransforms.apply_reading(strip_html(sent), note[:deck])
      if sent_text.empty?
        puts "#{prefix} [note #{note_id}] sentence text empty after stripping — skipping"
        stats[:skipped_empty] += 1
        db.remove_tags(note_id, PENDING_TAGS['sent']) unless options[:dry_run]
      elsif options[:dry_run]
        action = options[:check_existing] ? "would check #{sound_file(s_audio)}" : "would generate sentence audio (#{voice})"
        puts "#{prefix} #{truncate(sent_text)} — #{action} [DRY RUN]"
        stats[:sent_generated] += 1 unless options[:check_existing]
      else
        # The reading check needs furigana that describes this exact sentence
        # and gives every kanji a reading; otherwise it would flag (and respell)
        # the wrong words.
        segments = ReadingCheck.parse_furigana(strip_html(fields[Kaishi::SENTENCE_FURIGANA_IDX].to_s))
        # [[:space:]], not \s: \s is ASCII-only, and parse_furigana drops
        # full-width spaces too.
        skip_reason = if segments.map(&:text).join != strip_html(sent).gsub(/[[:space:]]/, '')
                        'sentence furigana missing or out of sync; not checked'
                      elsif !ReadingCheck.fully_annotated?(segments)
                        'sentence furigana leaves kanji without a reading; not checked'
                      end
        segments = nil if skip_reason
        existing = sound_file(s_audio) if options[:check_existing]
        note_jobs << { note_id: note_id, kind: 'sent', field_idx: SENTENCE_AUDIO_IDX,
                       voice: voice_from_filename(existing) || voice, existing_file: existing,
                       text: sent_text, style: sentence_style, segments: segments, deck: note[:deck],
                       skip_reason: skip_reason,
                       label: "#{prefix} #{truncate(sent_text)}" }
      end
    end

    next if note_jobs.empty?

    notes[note_id] = { fields: fields, pending: note_jobs.size, updated: false, done_kinds: [] }
    jobs.concat(note_jobs)
  end

  # Write a note's new audio fields, then clear the pending tags for the clips
  # that succeeded. Failed clips keep their tag for the next run.
  #
  # If the update fails (e.g. the collection is damaged), the new clips never
  # reach the note: report it on stdout (so it lands in a tee'd log), count it,
  # and tag the note pending so the next run retries it. --check-existing
  # doesn't tag up front, so this tag is its only retry signal.
  finish_note = lambda do |note_id, state|
    return unless state[:updated]

    begin
      db.update_note!(note_id, state[:fields])
    rescue AnkiConnect::Error => e
      stats[:error_update] += 1
      puts "  ✗ Failed to update note #{note_id} with its new audio: #{e.message[0, 300]}"
      db.add_tags(note_id, state[:done_kinds].map { |kind| PENDING_TAGS[kind] }) rescue nil
      return
    end
    db.remove_tags(note_id, state[:done_kinds].map { |kind| PENDING_TAGS[kind] })
  end

  # Phase 2: generate concurrently. Workers only call Gemini, one Client per
  # thread, and hand each result back over `results`. The main thread does all
  # logging and all AnkiConnect writes, updating each note once its last clip is
  # in. An InsufficientBalanceError or RateLimitedError (quota exceeded; we
  # don't know when it resets, so no retry) stops the workers pulling new jobs;
  # clips already in flight still land.
  #
  # With the reading check on, a worker also transcribes each clip it generates
  # and, when Whisper hears a different reading, regenerates once with the
  # misread words spelled in kana (see generate_checked below).
  abort_error = nil
  # Note IDs whose clip Gemini's content filter blocked, by job kind. These go to
  # the VOICEVOX fallback after the Gemini run.
  blocked = { 'word' => [], 'sent' => [] }

  tmpdir = Dir.mktmpdir('gemini-audio-')
  whisper_slots = SizedQueue.new(options[:whisper_jobs])
  options[:whisper_jobs].times { whisper_slots << true }

  # Write a take to a temp WAV and run the reading check on it, holding one of
  # the limited Whisper slots.
  check_take = lambda do |job, wav, mecab, attempt|
    path = File.join(tmpdir, "#{job[:note_id]}_#{job[:kind]}_#{attempt}.wav")
    File.binwrite(path, wav)
    whisper_slots.pop
    begin
      if job[:kind] == 'word'
        ReadingCheck.check_word(path, job[:reading], mecab)
      else
        ReadingCheck.check_sentence(path, job[:segments], mecab)
      end
    ensure
      whisper_slots << true
      File.delete(path) if File.exist?(path)
    end
  end

  describe = ->(segments) { segments.map { |seg| "#{seg.text}[#{seg.reading}]" }.join(' ') }

  # Generate one clip (or, with --check-existing, fetch the clip already in
  # Anki); with the reading check on, check it and retry once in kana if Whisper
  # hears a different reading. Returns a hash:
  #   result: the take to write, or nil to keep the existing audio unchanged;
  #   cost: USD for every take; log: lines to print;
  #   check: :ok, :retried, :skipped or nil (check off);
  #   abort_error: an InsufficientBalance/RateLimited error hit on the retry.
  # Errors from the first generation propagate to the worker.
  generate_checked = lambda do |client, mecab, anki, job|
    wav = nil
    if job[:existing_file]
      begin
        wav = anki.retrieve_media_file(job[:existing_file])
      rescue StandardError => e
        return { result: nil, cost: 0.0, check: :skipped,
                 log: ["couldn't fetch #{job[:existing_file]} (#{e.message[0, 100]}); left unchanged"] }
      end
    end

    if wav
      out = { result: nil, cost: 0.0, log: [], check: nil }
    else
      result = client.generate(job[:text], voice: job[:voice], style: job[:style])
      out = { result: result, cost: result.cost.to_f, log: [], check: nil }
      out[:log] << "#{job[:existing_file]} missing from collection.media; generated a new take" if job[:existing_file]
      wav = result.to_wav
    end
    return out unless options[:reading_check]

    word = job[:kind] == 'word'
    unless word ? job[:reading] : job[:segments]
      out[:check] = :skipped
      out[:log] << (word ? 'no reading on the card; not checked' : job[:skip_reason])
      return out
    end

    begin
      first = check_take.call(job, wav, mecab, 1)
      if word
        return out.merge(check: :ok) unless first[:flagged]

        retry_text = job[:reading]
        out[:log] << "reading check: heard #{first[:heard]}, expected #{job[:reading]}; retrying in kana"
      else
        if first[:unusable]
          out[:log] << "reading check: transcript unusable (heard #{first[:heard]}); keeping audio"
          return out.merge(check: :skipped)
        end
        return out.merge(check: :ok) if first[:flagged].empty?

        retry_text = job[:segments].map { |seg| first[:flagged].include?(seg) ? seg.reading : seg.text }.join
        retry_text = TextTransforms.apply_reading(retry_text, job[:deck])
        out[:log] << "reading check: #{describe.call(first[:flagged])} misheard (heard #{first[:heard]}); " \
                     "retrying as #{retry_text}"
      end

      # The kana retry is accepted without a second check: kana pins the
      # reading down, and re-checking mostly measures Whisper's own noise.
      retry_result = client.generate(retry_text, voice: job[:voice], style: job[:style])
      out[:cost] += retry_result.cost.to_f
      out.merge(result: retry_result, check: :retried)
    rescue GeminiTTS::InsufficientBalanceError, GeminiTTS::RateLimitedError => e
      out[:log] << "retry aborted (#{e.class.name.split('::').last}); keeping first audio"
      out.merge(check: :skipped, abort_error: e)
    rescue StandardError => e
      out[:log] << "reading check failed (#{e.message[0, 150]}); keeping audio"
      out.merge(check: :skipped)
    end
  end

  unless jobs.empty?
    queue = Queue.new
    jobs.each { |job| queue << job }
    results = Queue.new
    stop = false

    worker_count = [options[:jobs], jobs.size].min
    workers = Array.new(worker_count) do
      Thread.new do
        client = GeminiTTS::Client.new(default_model: options[:model])
        mecab = MecabController.new if options[:reading_check]
        anki = AnkiConnect.new if options[:check_existing] # reads only; writes stay on the main thread
        loop do
          break if stop
          job = begin
            queue.pop(true)
          rescue ThreadError
            break # queue drained
          end

          begin
            outcome = generate_checked.call(client, mecab, anki, job)
            stop = true if outcome[:abort_error]
            results << [job, outcome, nil]
          rescue GeminiTTS::InsufficientBalanceError, GeminiTTS::RateLimitedError => e
            stop = true
            results << [job, nil, e]
          rescue GeminiTTS::Error => e
            results << [job, nil, e]
          end
        end
      ensure
        results << :done
      end
    end

    begin
      finished_workers = 0
      while finished_workers < worker_count
        item = results.pop
        if item == :done
          finished_workers += 1
          next
        end

        job, outcome, error = item
        state = notes[job[:note_id]]
        kind_name = job[:kind] == 'word' ? 'word' : 'sentence'

        if outcome
          result = outcome[:result]
          stats[:cost] += outcome[:cost]
          abort_error ||= outcome[:abort_error]
          outcome[:log].each { |line| puts "#{job[:label]} — #{line}" }
          case outcome[:check]
          when :ok       then stats[:check_ok] += 1
          when :retried  then stats[:check_retried] += 1
          when :skipped  then stats[:check_skipped] += 1
          end
          if result.nil?
            # --check-existing, and the existing clip passed (or couldn't be
            # judged): leave the note alone.
            stats[:kept_existing] += 1
          else
            unless result.finish_reason == 'STOP'
              puts "      warning: finishReason=#{result.finish_reason} for #{job[:label]}"
            end
            # Kana retakes get their own name, so they're easy to spot and a
            # --check-existing retake never reuses the old file's name.
            suffix = outcome[:check] == :retried ? '_kana' : ''
            filename = "gemini_#{job[:note_id]}_#{job[:kind]}_#{job[:voice]}#{suffix}.wav"
            db.store_media_file(filename, data: apply_fade(result.to_wav))
            state[:fields][job[:field_idx]] = "[sound:#{filename}]"
            state[:updated] = true
            state[:done_kinds] << job[:kind]
            stats[job[:kind] == 'word' ? :word_generated : :sent_generated] += 1
            puts "#{job[:label]} — #{kind_name} audio generated (#{job[:voice]}#{suffix.empty? ? '' : ', kana retake'})"
          end
        else
          stat, desc = case error
                       when GeminiTTS::InsufficientBalanceError
                         abort_error ||= error
                         [:error_api, 'out of balance']
                       when GeminiTTS::RateLimitedError
                         abort_error ||= error
                         [:error_network, 'rate limited']
                       when GeminiTTS::ContentBlockedError
                         blocked[job[:kind]] << job[:note_id]
                         [:error_blocked, 'blocked']
                       when GeminiTTS::NoAudioError        then [:error_no_audio, 'no audio']
                       when GeminiTTS::NetworkError, GeminiTTS::ServerError
                         [:error_network, 'network/server error']
                       else [:error_api, 'API error']
                       end
          stats[stat] += 1
          puts "#{job[:label]} — #{kind_name} #{desc}: #{error.message[0, 200]}"
        end

        state[:pending] -= 1
        finish_note.call(job[:note_id], state) if state[:pending].zero?
      end
    ensure
      # On an early exit (e.g. an AnkiConnect error), let in-flight requests
      # finish but start no more.
      stop = true
      workers.each(&:join)
    end

    # After an abort, notes with one clip done and one never attempted still
    # need their finished clip written.
    notes.each do |note_id, state|
      finish_note.call(note_id, state) if state[:pending] > 0
    end
  end
  FileUtils.rm_rf(tmpdir)

  # Phase 3: fall back to VOICEVOX for clips the content filter blocked. The
  # filter is sensitive (e.g. any mention of children can trip
  # PROHIBITED_CONTENT) and deterministic, so retrying Gemini won't help. Runs
  # after every Gemini write has landed: generate-voicevox-audio.rb reads the
  # notes fresh and replaces only the blocked field.
  if options[:voicevox_fallback] && blocked.values.any?(&:any?) && !voicevox_running?
    puts ""
    puts "#{blocked.values.sum(&:size)} clip(s) were blocked by Gemini's content filter, and no VOICEVOX"
    puts "server is running at #{voicevox_url} for the fallback. They stay tagged audio::pending::*;"
    puts "start VOICEVOX and re-run to voice them, or ignore them."
  elsif options[:voicevox_fallback] && blocked.values.any?(&:any?)
    voicevox_script = File.join(__dir__, 'generate-voicevox-audio.rb')
    blocked.each do |kind, note_ids|
      next if note_ids.empty?

      puts ""
      puts "-" * 70
      puts "VOICEVOX fallback: #{note_ids.size} blocked #{kind == 'word' ? 'word' : 'sentence'} clip(s)"
      puts "-" * 70
      args = [RbConfig.ruby, voicevox_script, '--force', '--note-ids', note_ids.join(','),
              kind == 'word' ? '--word-only' : '--sentence-only']
      args += ['--target-deck', options[:target_deck]]
      if system(*args)
        stats[:blocked_fallback] += note_ids.size
        db.remove_tags(note_ids, PENDING_TAGS[kind])
      else
        puts "VOICEVOX fallback reported errors (see above); counting these clips as blocked."
      end
    end
  end

  errors = stats.values_at(:error_no_audio, :error_api, :error_network, :error_update).sum +
           stats[:error_blocked] - stats[:blocked_fallback]

  puts ""
  puts "=" * 70
  puts "SUMMARY"
  puts "=" * 70
  puts "  Notes processed:          #{stats[:total]}"
  puts "  Word audio generated:     #{stats[:word_generated]}"
  puts "  Sentence audio generated: #{stats[:sent_generated]}"
  puts "  Cost:                     $#{'%.4f' % stats[:cost]}"
  if options[:reading_check] && !options[:dry_run]
    puts ""
    puts "  Reading check passed:     #{stats[:check_ok]}"
    puts "  Retried in kana:          #{stats[:check_retried]}"
    puts "  Existing audio kept:      #{stats[:kept_existing]}" if options[:check_existing]
    puts "  Not checked:              #{stats[:check_skipped]}"
  end
  puts ""
  puts "  Skipped (existing):       #{stats[:skipped_existing]}"
  puts "  Skipped (empty text):     #{stats[:skipped_empty]}"
  puts "  Blocked, via VOICEVOX:    #{stats[:blocked_fallback]}"
  puts "  Errors (blocked):         #{stats[:error_blocked] - stats[:blocked_fallback]}"
  puts "  Errors (no audio):        #{stats[:error_no_audio]}"
  puts "  Errors (API):             #{stats[:error_api]}"
  puts "  Errors (network/server):  #{stats[:error_network]}"
  puts "  Errors (note update):     #{stats[:error_update]}"
  puts "=" * 70
  puts ""

  if abort_error
    # The full body names the exhausted quota (per-minute vs per-day) and any
    # suggested retry delay.
    reason = abort_error.is_a?(GeminiTTS::RateLimitedError) ? 'Gemini quota exceeded (HTTP 429)' : 'Gemini account balance exhausted'
    ProgressReporter.error("#{reason} — aborted. Notes not yet reached were left unchanged.")
    puts abort_error.message
    puts ""
    puts "Unfinished notes are tagged #{PENDING_TAGS.values.join(' / ')}. To resume, re-run"
    puts "the same command without --force."
  elsif options[:dry_run]
    puts "This was a dry run. No changes were made."
    puts "Run without --dry-run to apply changes."
  elsif stats[:word_generated] + stats[:sent_generated] > 0
    ProgressReporter.success("Done.")
  end

  exit ScriptCLI::EXIT_LIMIT if abort_error
  exit(errors > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
