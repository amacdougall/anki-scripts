# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'open3'
require 'date'
require_relative 'progress_reporter'

# Local JMdict dictionary: replaces the jisho.org web API for all lookups.
#
# jisho.org's word dictionary *is* JMdict, so everything we consumed from it
# (readings, English glosses, the "usually written in kana alone" flag, and
# part-of-speech / politeness tags) comes straight from JMdict. We use the
# jmdict-simplified distribution (https://github.com/scriptin/jmdict-simplified),
# which ships JMdict as regular-structured JSON with human-readable fields.
#
# The dataset is downloaded once into data/ and preprocessed into a Marshal'd
# lookup index (form => [entry JSON blobs]) for fast O(1) exact-form lookups
# without reparsing the whole dictionary on every CLI invocation; each matched
# entry's JSON is parsed lazily at lookup time. At most once every 30 days,
# the first lookup checks for a newer release and downloads it automatically;
# that check is best-effort and never blocks lookups when offline.
module JMDict
  class Error < StandardError; end

  DATA_DIR     = File.expand_path('../data', __dir__)
  DATASET_PATH = File.join(DATA_DIR, 'jmdict-eng.json')
  INDEX_PATH   = File.join(DATA_DIR, 'jmdict-index.marshal')
  META_PATH    = File.join(DATA_DIR, 'jmdict-meta.json')

  RELEASES_API = 'https://api.github.com/repos/scriptin/jmdict-simplified/releases/latest'
  USER_AGENT   = 'anki-example-sentence-builder'
  # Full English dataset has ~217k entries; guard against a truncated download.
  MIN_ENTRIES = 150_000
  HTTP_TIMEOUT = 30
  # Days to wait between update checks. jmdict-simplified ships weekly, but we
  # don't need the freshest data — one check per month is plenty.
  UPDATE_INTERVAL_DAYS = 30
  LOAD_LOCK = Mutex.new

  class << self
    # --- Public lookup API (drop-in for the old JishoClient) ---

    # All entries whose kanji or kana forms include +word+ exactly. Index values
    # are stored as JSON blobs (see build_index!) and parsed here, on demand.
    def entries_for(word)
      load!
      (@index[word] || []).map { |blob| JSON.parse(blob) }
    end

    # First matching entry (or nil), mirroring JishoClient.fetch_entry.
    def entry_for(word)
      entries_for(word).first
    end

    # Whether an entry includes +word+ as a kanji form or reading. Exact-key
    # lookup already guarantees this, but kept for parity with old callers.
    def entry_matches_word?(entry, word)
      kanji_forms(entry).include?(word) || readings(entry).include?(word)
    end

    # --- Per-entry accessors (jmdict-simplified shape, string keys) ---

    def kanji_forms(entry)
      (entry['kanji'] || []).map { |k| k['text'] }
    end

    def readings(entry)
      (entry['kana'] || []).map { |k| k['text'] }
    end

    def senses(entry)
      entry['sense'] || []
    end

    # Every partOfSpeech code across all senses (e.g. "vt", "n", "adj-na").
    def parts_of_speech(entry)
      senses(entry).flat_map { |s| s['partOfSpeech'] || [] }.uniq
    end

    # Every misc code across all senses (e.g. "uk", "on-mim", "hon").
    def misc_tags(entry)
      senses(entry).flat_map { |s| s['misc'] || [] }.uniq
    end

    # English glosses for a single sense, as an array of strings.
    def sense_glosses(sense)
      (sense['gloss'] || []).map { |g| g['text'] }
    end

    # --- Dataset lifecycle ---

    # Ensure a usable dataset+index exist, downloading if missing and checking
    # for updates at most once per calendar month. Called lazily on first lookup
    # (never at require time) so scripts that never look anything up never prompt.
    def ensure_current!
      return if @checked
      @checked = true

      meta = load_meta

      unless dataset_ready?
        if interactive?
          unless prompt_yes?('JMDict dictionary not found. Download now (~30 MB)?')
            raise Error, 'JMDict dictionary is required but was not downloaded.'
          end
        else
          puts 'JMDict dictionary not found; downloading (non-interactive)...'
        end
        download_latest!
        return
      end

      check_for_update(meta)
    end

    # Rebuild the Marshal index from an already-downloaded dataset (no network).
    def rebuild_index!
      raise Error, "Dataset not found at #{DATASET_PATH}" unless File.exist?(DATASET_PATH)

      build_index!(DATASET_PATH)
    end

    private

    # Locked so threads looking words up at once (e.g. generate-furigana.rb's
    # review workers) load the index only once.
    def load!
      return if @loaded

      LOAD_LOCK.synchronize do
        next if @loaded

        ensure_current!
        @index = Marshal.load(File.binread(INDEX_PATH))
        @loaded = true
      end
    end

    def dataset_ready?
      File.exist?(DATASET_PATH) && File.exist?(INDEX_PATH)
    end

    # Check for a newer release at most once every UPDATE_INTERVAL_DAYS, and
    # download it automatically if found. Best-effort: any network trouble warns
    # and keeps the existing dataset. We record the check date regardless of
    # outcome (new version, no new version, or failure), so the next check is a
    # full interval away either way.
    def check_for_update(meta)
      return unless update_due?(meta)

      latest = fetch_latest_release
      if latest.nil?
        ProgressReporter.warning('Could not check for JMDict updates; using existing dataset.')
      elsif latest[:version] != meta['version']
        puts "Newer JMDict available (#{latest[:version]}); updating..."
        download_release!(latest)
        return # download_release! rewrote meta, including last_checked
      end

      meta['last_checked'] = Date.today.iso8601
      save_meta(meta)
    end

    # Whether at least UPDATE_INTERVAL_DAYS have passed since the last check.
    # Missing or unparseable dates mean "check now".
    def update_due?(meta)
      last = meta['last_checked']
      return true if last.nil? || last.to_s.empty?

      (Date.today - Date.parse(last.to_s)).to_i >= UPDATE_INTERVAL_DAYS
    rescue ArgumentError
      true
    end

    def download_latest!
      latest = fetch_latest_release
      raise Error, 'Could not determine the latest JMDict release.' unless latest

      download_release!(latest)
    end

    # Download a release's full-English tarball, extract it, build the index,
    # and persist metadata.
    def download_release!(release)
      FileUtils.mkdir_p(DATA_DIR)
      tgz_path = File.join(DATA_DIR, File.basename(release[:asset_url]))

      puts 'Downloading JMDict (jmdict-simplified, full English)...'
      puts "  Version: #{release[:version]}"
      puts "  Source:  #{release[:asset_url]}"

      body = http_get(release[:asset_url])
      File.binwrite(tgz_path, body)
      puts "  Downloaded #{body.bytesize} bytes"

      json_path = extract_tarball(tgz_path)
      FileUtils.mv(json_path, DATASET_PATH, force: true)
      File.delete(tgz_path) if File.exist?(tgz_path)

      build_index!(DATASET_PATH)
      save_meta('version' => release[:version], 'last_checked' => Date.today.iso8601)

      ProgressReporter.success("JMDict #{release[:version]} ready.")
    end

    # Extract the single JSON file from a jmdict-simplified .json.tgz and return
    # its path. Shells out to tar (present on macOS/Linux), consistent with the
    # open3 usage in MecabController.
    def extract_tarball(tgz_path)
      _out, err, status = Open3.capture3('tar', '-xzf', tgz_path, '-C', DATA_DIR)
      raise Error, "Failed to extract #{tgz_path}: #{err}" unless status.success?

      # Asset "jmdict-eng-<ver>.json.tgz" extracts to "jmdict-eng-<ver>.json".
      json_name = File.basename(tgz_path, '.tgz')
      json_path = File.join(DATA_DIR, json_name)
      unless File.exist?(json_path)
        # Fall back to whichever jmdict-eng-*.json the tarball produced.
        json_path = Dir.glob(File.join(DATA_DIR, 'jmdict-eng-*.json')).first
      end
      raise Error, "Extracted JSON not found for #{tgz_path}" unless json_path && File.exist?(json_path)

      json_path
    end

    # Parse the dataset once and Marshal a { form => [entry JSON blob] } index
    # keyed by every kanji and kana form. Each entry is stored as its JSON
    # string rather than a parsed hash: Marshal.load then reconstructs ~460k
    # strings instead of ~10M nested objects, cutting load time from ~4.7s to
    # ~1.3s. Parsing is deferred to lookup time (entries_for), which is cheap
    # since no run touches more than a small fraction of entries. Each entry's
    # blob is a single shared String reused across its forms, so Marshal stores
    # it once.
    def build_index!(json_path)
      puts 'Building JMDict lookup index...'
      data = JSON.parse(File.read(json_path, encoding: 'UTF-8'))
      entries = data['words'] || []

      if entries.length < MIN_ENTRIES
        raise Error, "JMDict dataset looks incomplete (#{entries.length} entries)."
      end

      index = Hash.new { |h, k| h[k] = [] }
      entries.each do |entry|
        blob = JSON.generate(entry)
        (kanji_forms(entry) + readings(entry)).uniq.each { |form| index[form] << blob }
      end
      index.default = nil # drop the default proc so the index Marshals cleanly

      File.binwrite(INDEX_PATH, Marshal.dump(index))
      puts "  Indexed #{entries.length} entries across #{index.size} forms."
      @index = nil # force reload on next lookup
      @loaded = false
    end

    # --- Release metadata / networking ---

    # Returns { version:, asset_url: } for the latest release's full-English
    # tarball, or nil on any failure.
    def fetch_latest_release
      body = http_get(RELEASES_API)
      release = JSON.parse(body)
      version = release['tag_name']
      asset = (release['assets'] || []).find do |a|
        name = a['name'].to_s
        name.start_with?('jmdict-eng-') && name.end_with?('.json.tgz') && !name.include?('common')
      end
      return nil unless version && asset

      { version: version, asset_url: asset['browser_download_url'] }
    rescue StandardError => e
      warn "  Could not fetch JMDict release info: #{e.message}"
      nil
    end

    # GET a URL, following redirects (GitHub asset URLs 302 to S3). Returns the
    # raw response body (binary-safe).
    def http_get(url, limit = 5)
      raise Error, 'Too many redirects' if limit <= 0

      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                 open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = USER_AGENT
        request['Accept'] = 'application/octet-stream, application/json'
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        http_get(response['location'], limit - 1)
      else
        raise Error, "HTTP #{response.code} for #{url}"
      end
    end

    def load_meta
      return {} unless File.exist?(META_PATH)

      JSON.parse(File.read(META_PATH))
    rescue StandardError
      {}
    end

    def save_meta(meta)
      FileUtils.mkdir_p(DATA_DIR)
      File.write(META_PATH, JSON.pretty_generate(meta))
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
