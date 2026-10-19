# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require_relative '../lib/anki_connect'

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
          @cache = @status.call(nil).merge('deck_names' => @deck_names.call.sort)
          @cached_at = @clock.call
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

    def run_deck_status(deck)
      argv = [RbConfig.ruby, File.join(ROOT, 'deck-status.rb'), '--json']
      argv.push('--target-deck', deck) if deck
      out, err, status = Open3.capture3(*argv, chdir: ROOT)
      raise Error, (err.strip.empty? ? out : err).strip.lines.last(3).join unless status.success?

      JSON.parse(out)
    end
  end
end
