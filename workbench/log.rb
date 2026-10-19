# frozen_string_literal: true

module Workbench
  # What the Workbench is doing, for the terminal it was started from:
  # background commands (deck-status.rb) with their timing, runs starting and
  # finishing, AnkiConnect coming and going, and errors.
  #
  #   Log.info('deck-status.rb --json: done in 2.7s')
  #   Log.io = StringIO.new # tests
  module Log
    @io = $stdout
    @verbose = false
    @mutex = Mutex.new

    class << self
      attr_accessor :io, :verbose

      def info(message)
        write(message)
      end

      # Only with --verbose.
      def debug(message)
        write(message) if verbose
      end

      # Seconds since start, for "done in 2.7s".
      def elapsed(start)
        format('%.1fs', Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      private

      def write(message)
        return unless io

        @mutex.synchronize { io.puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}" }
      end
    end
  end
end
