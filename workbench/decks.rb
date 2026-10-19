# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require_relative '../lib/anki_connect'
require_relative 'log'

module Workbench
  # Per-deck counts from `deck-status.rb --json`, so the CLI stays the source
  # of truth for what "missing" means. The whole collection takes a few
  # seconds, so the result is cached; a finished run refreshes its own deck.
  class Decks
    ROOT = File.expand_path('..', __dir__)
    TTL = 30 # seconds

    class Error < StandardError; end

    # status: a callable returning deck-status.rb's parsed JSON for a deck
    # (nil for all decks); deck_names: a callable returning every deck name.
    # Tests pass stubs.
    def initialize(status: method(:run_deck_status), deck_names: -> { AnkiConnect.new.deck_names },
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @status = status
      @deck_names = deck_names
      @clock = clock
      @mutex = Mutex.new
      @cache = nil
      @cached_at = nil
    end

    # { checks:, decks:, takoboto_decks:, deck_names: } for the whole collection.
    def all(refresh: false)
      @mutex.synchronize do
        if refresh || @cache.nil? || @clock.call - @cached_at > TTL
          @cache = @status.call(nil).merge('deck_names' => fetch_deck_names.sort)
          @cached_at = @clock.call
        else
          Log.debug('Deck counts: using the cached copy')
        end
        @cache
      end
    end

    # Re-counts one deck and folds it into the cache. Returns its entry
    # ({ name:, total:, counts: }), or nil if it has no Kaishi cards.
    def refresh(name)
      result = @status.call(name)
      entry = result['decks'].first
      @mutex.synchronize do
        if @cache
          decks = @cache['decks'].reject { |d| d['name'] == name }
          decks << entry if entry
          @cache = @cache.merge('decks' => decks.sort_by { |d| d['name'] },
                                'takoboto_decks' => result['takoboto_decks'])
        end
      end
      entry
    end

    def invalidate
      @mutex.synchronize { @cache = nil }
    end

    private

    HEARTBEAT = 5 # seconds between "still running" lines

    # Logs the command, a line every few seconds while it runs (a sync in Anki
    # can hold AnkiConnect up), anything it prints to stderr, and the result.
    def run_deck_status(deck)
      argv = [RbConfig.ruby, File.join(ROOT, 'deck-status.rb'), '--json']
      argv.push('--target-deck', deck) if deck
      label = "deck-status.rb --json#{" --target-deck #{deck}" if deck}"
      Log.info("#{label}: counting #{deck ? 'one deck' : 'every deck'}…")
      start = Log.now
      out, err, status = Open3.popen3(*argv, chdir: ROOT) do |stdin, stdout, stderr, wait|
        stdin.close
        reader = Thread.new { stdout.read }
        errors = Thread.new do
          stderr.each_line.map { |line| line.chomp.tap { |l| Log.info("#{label}: #{l}") } }.join("\n")
        end
        Log.info("#{label}: still running (#{Log.elapsed(start)})") until wait.join(HEARTBEAT)
        [reader.value, errors.value, wait.value]
      end
      unless status.success?
        message = (err.strip.empty? ? out : err).strip.lines.last(3).join
        Log.info("#{label}: failed after #{Log.elapsed(start)} (exit #{status.exitstatus})")
        raise Error, message
      end

      result = JSON.parse(out)
      Log.info("#{label}: done in #{Log.elapsed(start)} (#{result['decks'].size} decks with Kaishi cards)")
      result
    end

    def fetch_deck_names
      start = Log.now
      names = @deck_names.call
      Log.debug("AnkiConnect deckNames: #{names.size} decks in #{Log.elapsed(start)}")
      names
    end
  end
end
