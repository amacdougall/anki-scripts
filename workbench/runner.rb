# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'time'

module Workbench
  # Runs a step's scripts, one run at a time, in a background thread. Each
  # run keeps its output in memory for the page (which follows it over
  # Server-Sent Events) and appends it to temp/workbench.log.
  #
  #   run = runner.start(plan) { |finished| decks.refresh(finished.deck) }
  #   run.wait_for_lines(0) # => [[line, ...], finished?]
  class Runner
    ROOT = File.expand_path('..', __dir__)
    LOG_PATH = File.join(ROOT, 'temp', 'workbench.log')
    KEEP = 20 # finished runs kept for the page

    class Busy < StandardError; end

    # The scripts' exit statuses (lib/script_cli.rb), as the page reports them.
    STATUSES = { 0 => 'succeeded', 1 => 'failed', 2 => 'usage_error', 3 => 'limit' }.freeze

    ANSI = /\e\[[0-9;?]*[A-Za-z]/

    class Run
      attr_reader :id, :step_id, :deck, :phase, :dry_run, :commands, :started_at

      def initialize(plan)
        @id = SecureRandom.hex(6)
        @step_id = plan.step.id
        @deck = plan.deck
        @phase = plan.phase
        @dry_run = plan.dry_run
        @commands = plan.displays
        @invocations = plan.invocations
        @started_at = Time.now
        @lines = []
        @status = 'running'
        @exit_code = nil
        @pid = nil
        @cancelled = false
        @mutex = Mutex.new
        @changed = ConditionVariable.new
      end

      attr_reader :invocations

      def status
        @mutex.synchronize { @status }
      end

      def finished?
        status != 'running'
      end

      # Lines from index on, waiting up to timeout seconds for one if there are
      # none yet. Returns [lines, finished?].
      def wait_for_lines(index, timeout: 15)
        @mutex.synchronize do
          @changed.wait(@mutex, timeout) if index >= @lines.size && @status == 'running'
          [@lines[index..] || [], @status != 'running']
        end
      end

      def to_h
        @mutex.synchronize do
          { id: @id, step: @step_id, deck: @deck, phase: @phase, dry_run: @dry_run, commands: @commands,
            status: @status, exit_code: @exit_code, cancelled: @cancelled, lines: @lines.size,
            started_at: @started_at.iso8601 }
        end
      end

      # --- Used by the runner ---

      def add_line(text, kind = 'out')
        @mutex.synchronize do
          @lines << { text: text, kind: kind }
          @changed.broadcast
        end
      end

      # Also delivers a cancel that came in before the script started.
      def pid=(pid)
        @mutex.synchronize do
          @pid = pid
          Process.kill('INT', -pid) if @cancelled
        end
      rescue Errno::ESRCH
        nil
      end

      # SIGINT to the script's process group, as Ctrl-C would, so its own
      # children (Whisper, VOICEVOX) stop too. The scripts are resumable.
      def cancel
        @mutex.synchronize do
          return false if @status != 'running'

          @cancelled = true
          Process.kill('INT', -@pid) if @pid
          true
        end
      rescue Errno::ESRCH
        true
      end

      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      def finish(status, exit_code)
        @mutex.synchronize do
          @status = status
          @exit_code = exit_code
          @changed.broadcast
        end
      end
    end

    # env: extra environment for the scripts (the server's own is passed
    # through). log_path: nil to skip the log file (tests).
    def initialize(env: {}, log_path: LOG_PATH, root: ROOT)
      @env = env
      @log_path = log_path
      @root = root
      @mutex = Mutex.new
      @runs = {}
      @active = nil
    end

    def active
      @mutex.synchronize { @active }
    end

    def find(id)
      @mutex.synchronize { @runs[id] }
    end

    def latest
      @mutex.synchronize { @runs.values.last }
    end

    # Starts a plan's invocations in sequence, stopping at the first non-zero
    # exit. Raises Busy if a run is already going. The block is called with the
    # run once it has finished.
    def start(plan, &on_finish)
      run = Run.new(plan)
      @mutex.synchronize do
        raise Busy, 'Another run is still going' if @active

        @active = run
        @runs[run.id] = run
        @runs.delete(@runs.keys.first) while @runs.size > KEEP
      end
      Thread.new { execute(run, on_finish) }
      run
    end

    private

    def execute(run, on_finish)
      status = 'succeeded'
      code = 0
      run.invocations.each_with_index do |invocation, i|
        break if run.cancelled?

        run.add_line("$ #{run.commands[i]}", 'cmd')
        code = spawn(run, invocation.argv)
        status = run.cancelled? ? 'cancelled' : STATUSES.fetch(code, 'failed')
        break unless status == 'succeeded'
      end
    rescue SystemCallError => e
      run.add_line("Couldn't start the script: #{e.message}", 'err')
      status = 'failed'
      code = nil
    ensure
      run.finish(status, code)
      log(run)
      @mutex.synchronize { @active = nil }
      begin
        on_finish&.call(run)
      rescue StandardError => e
        warn "Workbench: after-run hook failed: #{e.message}"
      end
    end

    # Runs one argv, streaming merged stdout and stderr into the run. Returns
    # the exit code (nil if killed by a signal).
    def spawn(run, argv)
      Open3.popen2e(@env, *argv, chdir: @root, pgroup: true) do |stdin, out, wait|
        stdin.close # nothing reads stdin; flags answer every prompt
        run.pid = wait.pid
        out.set_encoding(Encoding::UTF_8)
        out.each_line do |line|
          text = line.scrub.chomp.gsub(ANSI, '')
          text = text.split("\r").last.to_s if text.include?("\r")
          run.add_line(text)
        end
        result = wait.value
        result.exitstatus || (result.termsig == Signal.list['INT'] ? 130 : nil)
      end
    end

    def log(run)
      return unless @log_path

      FileUtils.mkdir_p(File.dirname(@log_path))
      lines, = run.wait_for_lines(0, timeout: 0)
      File.open(@log_path, 'a') do |f|
        f.puts "=== #{run.started_at.iso8601} #{run.step_id} #{run.deck}#{' (dry run)' if run.dry_run}: #{run.status}"
        lines.each { |line| f.puts line[:text] }
        f.puts
      end
    rescue SystemCallError => e
      warn "Workbench: couldn't write #{@log_path}: #{e.message}"
    end
  end
end
