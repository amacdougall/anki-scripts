# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'open3'
require_relative 'progress_reporter'

# Word-frequency lookups, backed by the JPDB v2 frequency dictionary.
#
# JPDB is a rank-based frequency list built from a large corpus of Japanese
# media (novels, visual novels, anime, news). It's one of the Yomitan
# frequency dictionaries the Kaishi 1.5k deck itself was ordered with, so the
# ranks it produces sit naturally alongside Kaishi's existing Frequency values
# (lower = more common; e.g. する ~11, 食べる ~184, 九つ ~22806).
#
# We consume the "Kana" edition distributed as a Yomitan dictionary zip
# (https://github.com/Kuuuube/yomitan-dictionaries). It's downloaded once into
# data/ and preprocessed into a Marshal'd { form => rank } index for fast O(1)
# exact-form lookups without reparsing the 30 MB source on every invocation.
# Unlike the JMdict dataset there's no update check: JPDB v2 is effectively
# static, so the source URL is pinned and only fetched when the index is
# missing. Bump SOURCE_URL by hand if a newer edition is ever published.
module FrequencyDatabase
  class Error < StandardError; end

  DATA_DIR   = File.expand_path('../data', __dir__)
  INDEX_PATH = File.join(DATA_DIR, 'frequency-index.marshal')

  # Pinned JPDB v2 (Kana) Yomitan dictionary. Download-once; not auto-updated.
  SOURCE_URL = 'https://github.com/Kuuuube/yomitan-dictionaries/raw/main/dictionaries/JPDB_v2.2_Frequency_Kana_2024-10-13.zip'
  USER_AGENT = 'anki-example-sentence-builder'
  HTTP_TIMEOUT = 60
  # The source ships ~338k term-meta entries; guard against a truncated build.
  MIN_FORMS = 100_000

  # Rank stored when JPDB has no entry for a word. Matches the sentinel the
  # original Kaishi cards use for out-of-dictionary words.
  UNRANKED = 9_999_999

  class << self
    # Frequency rank for +word+ (lower = more common), or nil if JPDB has no
    # entry for that surface form. +word+ should already be the bare form with
    # any ruby/HTML markup stripped (see .normalize_word).
    def rank(word)
      load!
      @index[word]
    end

    # Reduce a raw Kaishi Word field to the bare surface form used for lookup:
    # drop furigana readings (<rt>/<rp> content) and any remaining HTML tags,
    # e.g. "<ruby>様<rt>よう</rt></ruby>になる" => "様になる".
    def normalize_word(text)
      text.to_s
          .gsub(%r{<r([tp])\b[^>]*>.*?</r\1>}mi, '') # drop reading annotations
          .gsub(/<[^>]*>/, '')                        # drop remaining tags (ruby, etc.)
          .strip
    end

    private

    def load!
      return if @loaded

      ensure_index!
      @index = Marshal.load(File.binread(INDEX_PATH))
      @loaded = true
    end

    # Build the index on first use if it isn't already on disk.
    def ensure_index!
      return if File.exist?(INDEX_PATH)

      if interactive? && !prompt_yes?('Frequency dictionary not found. Download now (~6 MB)?')
        raise Error, 'Frequency dictionary is required but was not downloaded.'
      end

      download_and_build!
    end

    # Fetch the pinned zip, extract its term_meta_bank JSON, and build the index.
    def download_and_build!
      FileUtils.mkdir_p(DATA_DIR)
      zip_path = File.join(DATA_DIR, File.basename(SOURCE_URL))

      puts 'Downloading JPDB v2 frequency dictionary...'
      puts "  Source: #{SOURCE_URL}"
      body = http_get(SOURCE_URL)
      File.binwrite(zip_path, body)
      puts "  Downloaded #{body.bytesize} bytes"

      extract_dir = File.join(DATA_DIR, 'frequency-extract')
      FileUtils.rm_rf(extract_dir)
      begin
        unzip(zip_path, extract_dir)
        build_index!(extract_dir)
      ensure
        FileUtils.rm_rf(extract_dir)
        File.delete(zip_path) if File.exist?(zip_path)
      end
    end

    # Parse every term_meta_bank_*.json in +dir+ and Marshal a
    # { form => rank } index. A form can appear many times (multiple readings
    # plus a written-in-kana variant); we keep the smallest rank, i.e. the
    # most common word/spelling sharing that surface form.
    def build_index!(dir)
      banks = Dir.glob(File.join(dir, 'term_meta_bank_*.json')).sort
      raise Error, "No term_meta_bank files found in #{dir}" if banks.empty?

      puts 'Building frequency lookup index...'
      index = {}
      banks.each do |bank|
        JSON.parse(File.read(bank, encoding: 'UTF-8')).each do |form, mode, data|
          next unless mode == 'freq'

          value = frequency_value(data)
          next if value.nil?

          current = index[form]
          index[form] = value if current.nil? || value < current
        end
      end

      if index.size < MIN_FORMS
        raise Error, "Frequency dictionary looks incomplete (#{index.size} forms)."
      end

      File.binwrite(INDEX_PATH, Marshal.dump(index))
      puts "  Indexed #{index.size} forms."
      ProgressReporter.success('Frequency dictionary ready.')
    end

    # Pull the numeric rank out of a Yomitan freq meta value, which comes in a
    # few shapes:
    #   {"value" => 11, "displayValue" => "11㋕"}                       (kana headword)
    #   {"reading" => "たべる", "frequency" => {"value" => 184, ...}}   (kanji headword)
    #   {"reading" => "…", "frequency" => 184}                          (bare int form)
    #   184  /  "184"                                                   (plainest form)
    def frequency_value(data)
      case data
      when Integer then data
      when String  then data.to_i
      when Hash
        if data.key?('frequency')
          frequency_value(data['frequency'])
        elsif data.key?('value')
          data['value']
        end
      end
    end

    def unzip(zip_path, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      _out, err, status = Open3.capture3('unzip', '-o', '-q', zip_path, '-d', dest_dir)
      raise Error, "Failed to unzip #{zip_path}: #{err}" unless status.success?
    end

    # GET a URL, following redirects (GitHub raw URLs 302 to their CDN).
    def http_get(url, limit = 5)
      raise Error, 'Too many redirects' if limit <= 0

      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                 open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = USER_AGENT
        request['Accept'] = 'application/octet-stream'
        http.request(request)
      end

      case response
      when Net::HTTPSuccess      then response.body
      when Net::HTTPRedirection  then http_get(response['location'], limit - 1)
      else raise Error, "HTTP #{response.code} for #{url}"
      end
    end

    def interactive?
      $stdin.tty?
    end

    def prompt_yes?(question)
      print "#{question} (y/n): "
      answer = $stdin.gets
      return false if answer.nil?

      %w[y yes].include?(answer.chomp.strip.downcase)
    end
  end
end
