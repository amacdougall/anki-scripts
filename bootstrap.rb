#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: installs gems, downloads the dictionaries and data files the
# scripts need into data/, then checks the rest of the environment (Anki,
# AnkiConnect, the Kaishi 1.5k note type, LLM CLIs, Gemini key, Whisper).
#
# Safe to re-run: finished downloads are skipped. Run with --check to skip the
# setup steps and only report on the environment.
#
#   data/unidic-lite/              UniDic dictionary for MeCab (~250 MB)
#   data/jmdict-*                  JMdict, English (refreshed monthly on use)
#   data/kanjidic2_readings.json   per-kanji readings from KANJIDIC2
#   data/wadoku_pitchdb.csv        pitch accent data from Wadoku
#   data/frequency-index.marshal   JPDB word frequency ranks

require 'digest'
require 'fileutils'
require 'net/http'
require 'open3'
require 'rbconfig'

ROOT = __dir__
DATA_DIR = File.join(ROOT, 'data')

PITCH_DB_URL = 'https://raw.githubusercontent.com/IllDepence/anki_add_pitch_plugin/master/src/wadoku_pitchdb.csv'
PITCH_DB_SHA256 = '5517407a34a54247df7941bf7f6678006fa83ac114699090d825f7783f10116c'
PITCH_DB_PATH = File.join(DATA_DIR, 'wadoku_pitchdb.csv')

KAISHI_FIELDS = [
  'Word', 'Word Reading', 'Word Meaning', 'Word Furigana', 'Word Audio',
  'Sentence', 'Sentence Meaning', 'Sentence Furigana', 'Sentence Audio',
  'Notes', 'Pitch Accent', 'Pitch Accent Notes', 'Frequency', 'Picture'
].freeze

def step(title)
  puts
  puts "== #{title}"
  yield
rescue StandardError => e
  puts "   FAILED: #{e.message}"
  @failures << title
end

def ok(msg) = puts("   ok    #{msg}")
def warn_line(msg) = puts("   --    #{msg}")
def bad(msg) = puts("   !!    #{msg}")

def on_path?(cmd)
  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, cmd)) }
end

def http_get(url, limit = 5)
  raise "too many redirects for #{url}" if limit.zero?

  response = Net::HTTP.get_response(URI(url))
  case response
  when Net::HTTPSuccess     then response.body
  when Net::HTTPRedirection then http_get(response['location'], limit - 1)
  else raise "HTTP #{response.code} for #{url}"
  end
end

# --- Setup -----------------------------------------------------------------

def setup!
  step('Ruby gems') do
    raise "Ruby 3.2 or newer is required (this is #{RUBY_VERSION})" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.2')

    system('bundle', 'install', '--quiet', chdir: ROOT) or raise 'bundle install failed'
    ok 'bundle install'
  end

  # The data libraries prompt before downloading when run from a terminal;
  # running this script is the consent, so make them non-interactive.
  $stdin = File.open(File::NULL)

  step('UniDic (MeCab dictionary)') do
    require_relative 'lib/unidic'
    UniDic.ensure_installed!
    ok 'data/unidic-lite'
  end

  step('JMdict') do
    require_relative 'lib/jmdict'
    JMDict.ensure_current!
    ok 'data/jmdict-eng.json'
  end

  step('KANJIDIC2 readings') do
    path = File.join(DATA_DIR, 'kanjidic2_readings.json')
    unless File.exist?(path)
      system(RbConfig.ruby, File.join(ROOT, 'scripts', 'build_kanjidic2_json.rb')) or raise 'build failed'
    end
    ok 'data/kanjidic2_readings.json'
  end

  step('Wadoku pitch accent database') do
    unless File.exist?(PITCH_DB_PATH)
      puts '   Downloading wadoku_pitchdb.csv (~20 MB)...'
      body = http_get(PITCH_DB_URL)
      actual = Digest::SHA256.hexdigest(body)
      raise "checksum mismatch (got #{actual})" unless actual == PITCH_DB_SHA256

      FileUtils.mkdir_p(DATA_DIR)
      File.binwrite(PITCH_DB_PATH, body)
    end
    ok 'data/wadoku_pitchdb.csv'
  end

  step('JPDB word frequency (for sort-new-by-word-frequency.rb)') do
    require_relative 'lib/frequency_database'
    FrequencyDatabase.rank('日本')
    ok 'data/frequency-index.marshal'
  end

  step('MeCab') do
    require_relative 'lib/mecab_controller'
    furigana = MecabController.new.generate_furigana('今日は学校に行きます')
    raise "unexpected output: #{furigana.inspect}" unless furigana.include?('学校[がっこう]')

    ok "今日は学校に行きます → #{furigana}"
  end
end

# --- Environment check -----------------------------------------------------

def check!
  step('Anki') do
    require_relative 'lib/anki_connect'
    db = AnkiConnect.new
    begin
      db.version
    rescue AnkiConnect::NotRunningError
      bad 'AnkiConnect not reachable: start Anki, and install the AnkiConnect add-on (code 2055492159)'
      @problems += 1
      next
    rescue AnkiConnect::Error => e
      bad e.message
      @problems += 1
      next
    end
    ok 'AnkiConnect is running'

    if db.find_note_type_id('Kaishi 1.5k')
      fields = db.field_names('Kaishi 1.5k')
      if fields == KAISHI_FIELDS
        ok 'Kaishi 1.5k note type found, with the expected fields'
      else
        bad "Kaishi 1.5k fields differ from what the scripts expect:\n" \
            "            expected #{KAISHI_FIELDS.join(', ')}\n" \
            "            found    #{fields.join(', ')}"
        @problems += 1
      end
    else
      bad 'Kaishi 1.5k note type not found: install the Kaishi 1.5k deck from AnkiWeb (it brings the note type)'
      @problems += 1
    end
  end

  step('LLM CLIs (sentences, translations, furigana review)') do
    found = %w[claude opencode].select { |cmd| on_path?(cmd) }
    if found.empty?
      bad 'neither `claude` nor `opencode` is on PATH; install one (see README)'
      @problems += 1
    else
      found.each { |cmd| ok "#{cmd} found" }
    end
  end

  step('Gemini TTS (audio)') do
    key_path = File.expand_path('~/.config/gemini/api_key')
    if !ENV['GEMINI_API_KEY'].to_s.strip.empty?
      ok 'GEMINI_API_KEY is set'
    elsif File.exist?(key_path)
      ok "API key in #{key_path}"
    else
      warn_line "no API key yet (needed only for generate-gemini-audio.rb; see README)"
    end
  end

  step('Whisper (optional audio reading check)') do
    if system(File.join(ROOT, 'bin', 'transcribe'), '--check')
      ok 'whisper-cli and model found'
    else
      warn_line 'not set up; generate-gemini-audio.rb will skip the reading check (./setup-whisper.sh enables it)'
    end
  end
end

@failures = []
@problems = 0
setup! unless ARGV.include?('--check')
check!

puts
if @failures.any?
  puts "Setup steps failed: #{@failures.join(', ')}. Fix the errors above and re-run."
  exit 1
elsif @problems.positive?
  puts 'Setup done, but see the !! lines above before running the scripts.'
else
  puts 'All set. See README.md for the workflow.'
end
