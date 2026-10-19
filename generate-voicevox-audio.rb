#!/usr/bin/env ruby

require 'open3'
require 'uri'
require 'json'
require_relative 'lib/script_cli'
require_relative 'lib/text_transforms'
require_relative 'lib/tts_text'

# VOICEVOX server: the engine's default local address, or VOICEVOX_URL if set
# (e.g. http://192.168.0.10:50021 for a server on another machine).
VOICEVOX_URL = ENV.fetch('VOICEVOX_URL', 'http://127.0.0.1:50021').chomp('/')

# Anki field indices (Kaishi 1.5k note type)
WORD_AUDIO_IDX     = Kaishi::WORD_AUDIO_IDX
SENTENCE_AUDIO_IDX = Kaishi::SENTENCE_AUDIO_IDX

# Speaker pools — ノーマル/natural styles, split by gender
FEMALE_SPEAKERS = [
  2,   # 四国めたん
  8,   # 春日部つむぎ
  14,  # 冥鳴ひまり
  20,  # もち子さん
  74,  # 琴詠ニア
].freeze

MALE_SPEAKERS = [
  11,  # 玄野武宏
  13,  # 青山龍星
  52,  # 雀松朱司
  53,  # 麒ヶ島宗麟
  100, # 黒沢冴白
].freeze

SPEAKERS = (MALE_SPEAKERS + FEMALE_SPEAKERS).freeze

# Word audio is generated inside a fixed carrier phrase rather than in
# isolation — VOICEVOX's training data is all in-sentence speech, so a lone
# word synthesized by itself can glitch or mispronounce. The two 、 reliably
# produce a pause_mora in the audio_query response's accent_phrases, which
# gives a purely structural way to find the word's span afterward (see
# locate_word_span) — no reading/text matching against real sentence text
# required. Validated against a 1-mora word, a multi-phrase idiom, and a
# homograph.
CARRIER_PREFIX = 'この録音のために、'
CARRIER_SUFFIX = '、と言っています'

# Extra silence kept on each side of the extracted word, pulled from the
# comma pause (otherwise pure silence) so the cut doesn't land exactly on a
# phoneme boundary.
CARRIER_PAD_SECONDS = 0.05


# Retry config for transient network errors
MAX_RETRIES = 2
RETRY_DELAY = 2

# curl exit codes that indicate a transient connection failure (worth retrying)
# 6=can't resolve host, 7=connection refused, 28=timeout, 35=SSL, 56=recv failure
CURL_NETWORK_EXIT_CODES = [6, 7, 28, 35, 56].freeze

NetworkError = Class.new(StandardError)

# ---

cli = ScriptCLI.new(
  'generate-voicevox-audio.rb',
  'Generates Japanese audio via a VOICEVOX server for cards missing it. Mostly used',
  "as generate-gemini-audio.rb's fallback for clips Gemini's content filter blocks."
)
options = cli.options
options.merge!(word_only: false, sentence_only: false, word_ruby_only: false, note_ids: nil)
cli.dry_run('Preview without writing files or modifying Anki')
cli.limit
cli.force('Regenerate audio even if already present')
cli.on("--word-only", "Only generate word audio (field #{WORD_AUDIO_IDX})") do
  options[:word_only] = true
end
cli.on("--sentence-only", "Only generate sentence audio (field #{SENTENCE_AUDIO_IDX})") do
  options[:sentence_only] = true
end
cli.on("--note-ids IDS", Array, "Restrict to these note IDs (comma-separated); used by generate-gemini-audio.rb's fallback") do |ids|
  options[:note_ids] = ids.map { |id| Integer(id) }
end
cli.on("--word-ruby-only", "Regenerate word audio only for words with <ruby> furigana, using the ruby reading for TTS") do
  options[:word_ruby_only] = true
  options[:word_only]      = true
  options[:force]          = true
end
cli.parse!

# ---

include TtsText

# Select a speaker from the pool matching the note's voice gender preference
# (see TtsText.voice_gender). Returns a speaker ID.
def select_speaker(note)
  case TtsText.voice_gender(note)
  when 'female' then FEMALE_SPEAKERS.sample
  when 'male'   then MALE_SPEAKERS.sample
  else               SPEAKERS.sample
  end
end

def apply_text_transforms(text, deck_name)
  TextTransforms.apply_reading(text, deck_name)
end

# Extract the kana reading VOICEVOX plans to use from an audio_query response.
def extract_reading_from_query(query_data)
  query_data['accent_phrases'].flat_map { |phrase|
    moras = phrase['moras'].map { |m| m['text'] }
    moras << phrase['pause_mora']['text'] if phrase['pause_mora']
    moras
  }.join
end

# Reading of a subset of accent_phrases (moras only, no pause_mora text) —
# used to check the word's own pronunciation within a carrier phrase, where
# the trailing phrase's pause_mora is carrier punctuation, not word content.
def extract_reading_from_phrases(phrases)
  phrases.flat_map { |phrase| phrase['moras'].map { |m| m['text'] } }.join
end

# Locate a word embedded in a carrier phrase built with CARRIER_PREFIX/SUFFIX.
# Returns [start_seconds, end_seconds, word_phrases] in the *raw*
# (speedScale=1.0) time base the audio_query response's mora lengths use,
# plus the accent_phrases belonging to the word (for reading verification).
#
# The carrier's two 、 reliably produce a pause_mora on the accent_phrase
# that precedes each comma. The word occupies every phrase strictly after
# the first such boundary through (and including) the second.
def locate_word_span(query_data)
  phrases = query_data['accent_phrases']
  cumulative = query_data['prePhonemeLength']
  speech_end = {}
  pause_end  = {}

  phrases.each_with_index do |ap, i|
    ap['moras'].each { |m| cumulative += (m['consonant_length'] || 0) + m['vowel_length'] }
    speech_end[i] = cumulative
    cumulative += ap['pause_mora']['vowel_length'] if ap['pause_mora']
    pause_end[i] = cumulative
  end

  paused_indices = phrases.each_index.select { |i| phrases[i]['pause_mora'] }
  if paused_indices.size < 2
    raise "expected 2 comma-induced pauses in carrier phrase, found #{paused_indices.size}"
  end

  p1, p2 = paused_indices[0], paused_indices[1]
  [pause_end[p1], speech_end[p2], phrases[(p1 + 1)..p2]]
end

# Slice [start_sample, end_sample) out of a WAV, rewriting the header's size
# fields (ChunkSize, Subchunk2Size) to match the shorter data length.
def slice_wav(wav_bytes, start_sample, end_sample)
  wav_bytes = wav_bytes.b
  samples = wav_bytes[44..].unpack('s<*')
  start_sample = start_sample.clamp(0, samples.length)
  end_sample   = end_sample.clamp(start_sample, samples.length)
  sliced = samples[start_sample...end_sample]

  data_size = sliced.length * 2 # 16-bit = 2 bytes/sample
  header = wav_bytes[0, 44].dup
  header[4, 4]  = [36 + data_size].pack('V')
  header[40, 4] = [data_size].pack('V')

  header + sliced.pack('s<*')
end

# Kana whose vowel is お or え — used for long vowel normalization.
O_COLUMN_KANA = 'おこそとのほもよろをごぞどぼぽょ'
E_COLUMN_KANA = 'えけせてねへめれげぜでべぺ'

# Normalize a reading for comparison: katakana → hiragana, strip whitespace,
# and expand long vowel markers to match VOICEVOX's phonetic representation
# (e.g. しょうぶ → しょおぶ, せいかつ → せえかつ).
def normalize_reading(reading)
  reading
    .tr('ァ-ヶ', 'ぁ-ゖ')
    .gsub(/\s+/, '')
    .gsub(/([#{O_COLUMN_KANA}])う/, '\1お')
    .gsub(/([#{E_COLUMN_KANA}])い/, '\1え')
end

# Call VOICEVOX audio_query endpoint. Returns parsed JSON.
# Retries on curl connection errors; raises immediately on HTTP errors.
def audio_query(text, speaker_id)
  attempt = 0
  begin
    attempt += 1
    encoded = URI.encode_www_form_component(text)
    url = "#{VOICEVOX_URL}/audio_query?text=#{encoded}&speaker=#{speaker_id}"
    json, status = Open3.capture2(
      'curl', '-s', '--fail', '-X', 'POST',
      '-H', 'Content-Type: application/json',
      url
    )
    unless status.success?
      code = status.exitstatus
      raise(CURL_NETWORK_EXIT_CODES.include?(code) ? NetworkError : StandardError,
            "audio_query failed (curl exit #{code})")
    end
    JSON.parse(json)
  rescue NetworkError => e
    if attempt <= MAX_RETRIES
      puts "      Connection error (attempt #{attempt}/#{MAX_RETRIES + 1}): #{e.message}. Retrying in #{RETRY_DELAY}s..."
      sleep RETRY_DELAY
      retry
    else
      raise
    end
  end
end

# Call VOICEVOX synthesis endpoint. Returns WAV bytes.
# Retries on curl connection errors; raises immediately on HTTP errors.
def synthesis(query_data, speaker_id)
  attempt = 0
  begin
    attempt += 1
    url = "#{VOICEVOX_URL}/synthesis?speaker=#{speaker_id}"
    query_json = JSON.generate(query_data)
    wav_bytes, status = Open3.capture2(
      'curl', '-s', '--fail', '-X', 'POST',
      '-H', 'Content-Type: application/json',
      '-H', 'Accept: audio/wav',
      '--data-binary', '@-',
      url,
      stdin_data: query_json
    )
    unless status.success?
      code = status.exitstatus
      raise(CURL_NETWORK_EXIT_CODES.include?(code) ? NetworkError : StandardError,
            "synthesis failed (curl exit #{code})")
    end
    wav_bytes
  rescue NetworkError => e
    if attempt <= MAX_RETRIES
      puts "      Connection error (attempt #{attempt}/#{MAX_RETRIES + 1}): #{e.message}. Retrying in #{RETRY_DELAY}s..."
      sleep RETRY_DELAY
      retry
    else
      raise
    end
  end
end

# High-level: audio_query + synthesis → WAV bytes. Used for sentence audio.
def synthesize(text, speaker_id)
  query_data = audio_query(text, speaker_id)
  query_data['speedScale'] = 0.8
  synthesis(query_data, speaker_id)
end

# ---

db = cli.connect!

# Pre-flight: verify VOICEVOX is reachable before generating audio
puts "Checking VOICEVOX at #{VOICEVOX_URL}..."
begin
  out, status = Open3.capture2(
    'curl', '-s', '--max-time', '5',
    "#{VOICEVOX_URL}/version"
  )
  raise "curl exited with #{status.exitstatus}" unless status.success?
  version = out.strip.delete('"')
  ProgressReporter.success("VOICEVOX #{version} is reachable")
rescue => e
  ProgressReporter.error("Cannot reach VOICEVOX: #{e.message}")
  puts "Make sure VOICEVOX is running at #{VOICEVOX_URL}"
  exit ScriptCLI::EXIT_ERROR
end
puts ""

begin
  # Each note carries its deck name (a subdeck's, for notes in one) so the
  # right deck's TextTransforms fire.
  all_notes = cli.notes(db, with_deck: true)
  ProgressReporter.success("Found #{all_notes.size} #{Kaishi::NOTE_TYPE_NAME} notes")

  if options[:note_ids]
    all_notes = all_notes.select { |note| options[:note_ids].include?(note[:id]) }
    puts "Restricted to #{all_notes.size} of #{options[:note_ids].size} requested note IDs"
  end
  puts ""

  notes_to_process = all_notes.select do |note|
    f = note[:fields]
    word = f[Kaishi::WORD_IDX].to_s.strip
    sent = f[Kaishi::SENTENCE_IDX].to_s.strip
    w_audio = f[WORD_AUDIO_IDX].to_s.strip
    s_audio = f[SENTENCE_AUDIO_IDX].to_s.strip

    needs_word = !options[:sentence_only] && (options[:force] || w_audio.empty?) && !word.empty?
    needs_sent = !options[:word_only]     && (options[:force] || s_audio.empty?) && !sent.empty?

    needs_word || needs_sent
  end

  notes_to_process = notes_to_process.take(options[:limit]) if options[:limit]

  puts "Notes to process: #{notes_to_process.size}"
  puts ""

  if notes_to_process.empty?
    puts "No notes need audio generation."
    puts "Use --force to regenerate existing audio." unless options[:force]
    exit ScriptCLI::EXIT_OK
  end

  stats = {
    total:             notes_to_process.size,
    word_generated:    0,
    sent_generated:    0,
    reading_overrides: 0,
    skipped_existing:  0,
    skipped_empty:     0,
    error_api:         0,
    error_network:     0
  }

  puts options[:dry_run] ? "Preview mode (no changes will be made):" : "Processing notes:"
  puts ""

  db.transaction do
    notes_to_process.each_with_index do |note, idx|
      note_id    = note[:id]
      fields     = note[:fields]
      speaker_id = select_speaker(note)
      updated    = false

      word    = fields[Kaishi::WORD_IDX].to_s
      sent    = fields[Kaishi::SENTENCE_IDX].to_s
      w_audio = fields[WORD_AUDIO_IDX].to_s.strip
      s_audio = fields[SENTENCE_AUDIO_IDX].to_s.strip

      prefix = "[#{idx + 1}/#{stats[:total]}]"

      # -- Word audio --
      unless options[:sentence_only]
        if !options[:force] && !w_audio.empty?
          stats[:skipped_existing] += 1
        else
          next if options[:word_ruby_only] && !word.include?('<ruby>')

          word_raw  = word_tts_text(word)
          word_text = apply_text_transforms(word_raw, note[:deck])
          word_transformed = word_text != word_raw
          if word_text.empty?
            puts "#{prefix} [note #{note_id}] word text empty after stripping — skipping"
            stats[:skipped_empty] += 1
          elsif options[:dry_run]
            puts "#{prefix} #{word_text} — would generate word audio (speaker #{speaker_id}) [DRY RUN]"
            stats[:word_generated] += 1
          else
            begin
              carrier_word_text = word_text
              query_data = audio_query("#{CARRIER_PREFIX}#{carrier_word_text}#{CARRIER_SUFFIX}", speaker_id)
              raw_start, raw_end, word_phrases = locate_word_span(query_data)

              planned_reading = normalize_reading(extract_reading_from_phrases(word_phrases))
              expected_reading = normalize_reading(strip_html(fields[Kaishi::WORD_READING_IDX].to_s))

              if !word_transformed && planned_reading != expected_reading && !expected_reading.empty?
                puts "#{prefix} Reading mismatch: VOICEVOX=#{planned_reading} expected=#{expected_reading}, retrying with kana"
                carrier_word_text = expected_reading
                query_data = audio_query("#{CARRIER_PREFIX}#{carrier_word_text}#{CARRIER_SUFFIX}", speaker_id)
                raw_start, raw_end, _word_phrases = locate_word_span(query_data)
                stats[:reading_overrides] += 1
              end

              query_data['speedScale'] = 0.8
              carrier_wav  = synthesis(query_data, speaker_id)
              sample_rate  = query_data['outputSamplingRate']
              start_time   = (raw_start / query_data['speedScale']) - CARRIER_PAD_SECONDS
              end_time     = (raw_end   / query_data['speedScale']) + CARRIER_PAD_SECONDS
              wav = apply_fade(
                slice_wav(carrier_wav, (start_time * sample_rate).round, (end_time * sample_rate).round),
                sample_rate: sample_rate
              )
              filename = "voicevox_#{note_id}_word_#{speaker_id}.wav"
              db.store_media_file(filename, data: wav)
              fields[WORD_AUDIO_IDX] = "[sound:#{filename}]"
              updated = true
              stats[:word_generated] += 1
              puts "#{prefix} #{word_text} — word audio generated (speaker #{speaker_id})"
            rescue NetworkError => e
              puts "#{prefix} #{word_text} — network error: #{e.message}"
              stats[:error_network] += 1
            rescue => e
              puts "#{prefix} #{word_text} — API error: #{e.message}"
              stats[:error_api] += 1
            end
          end
        end
      end

      # -- Sentence audio --
      unless options[:word_only]
        if !options[:force] && !s_audio.empty?
          stats[:skipped_existing] += 1
        else
          sent_text = apply_text_transforms(strip_html(sent), note[:deck])
          if sent_text.empty?
            puts "#{prefix} [note #{note_id}] sentence text empty after stripping — skipping"
            stats[:skipped_empty] += 1
          elsif options[:dry_run]
            puts "#{prefix} #{sent_text[0, 50]}#{'...' if sent_text.length > 50} — would generate sentence audio (speaker #{speaker_id}) [DRY RUN]"
            stats[:sent_generated] += 1
          else
            begin
              wav      = synthesize(sent_text, speaker_id)
              filename = "voicevox_#{note_id}_sent_#{speaker_id}.wav"
              db.store_media_file(filename, data: apply_fade(wav))
              fields[SENTENCE_AUDIO_IDX] = "[sound:#{filename}]"
              updated = true
              stats[:sent_generated] += 1
              puts "#{prefix} #{sent_text[0, 50]}#{'...' if sent_text.length > 50} — sentence audio generated (speaker #{speaker_id})"
            rescue NetworkError => e
              puts "#{prefix} [note #{note_id}] sentence — network error: #{e.message}"
              stats[:error_network] += 1
            rescue => e
              puts "#{prefix} [note #{note_id}] sentence — API error: #{e.message}"
              stats[:error_api] += 1
            end
          end
        end
      end

      db.update_note(note_id, fields) if updated
    end
  end

  puts ""
  puts "=" * 70
  puts "SUMMARY"
  puts "=" * 70
  puts "  Notes processed:          #{stats[:total]}"
  puts "  Word audio generated:     #{stats[:word_generated]}"
  puts "  Sentence audio generated: #{stats[:sent_generated]}"
  puts "  Reading overrides:        #{stats[:reading_overrides]}"
  puts ""
  puts "  Skipped (existing):       #{stats[:skipped_existing]}"
  puts "  Skipped (empty text):     #{stats[:skipped_empty]}"
  puts "  Errors (API):             #{stats[:error_api]}"
  puts "  Errors (network):         #{stats[:error_network]}"
  puts "=" * 70
  puts ""

  if options[:dry_run]
    puts "This was a dry run. No changes were made."
    puts "Run without --dry-run to apply changes."
  elsif stats[:word_generated] + stats[:sent_generated] > 0
    ProgressReporter.success("Done.")
  end

  exit((stats[:error_api] + stats[:error_network]) > 0 ? ScriptCLI::EXIT_ERROR : ScriptCLI::EXIT_OK)

ensure
  db.close
end
