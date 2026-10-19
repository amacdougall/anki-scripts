# frozen_string_literal: true

require 'rbconfig'
require_relative 'command'
require_relative 'steps'

module Workbench
  # Collection backups: when the last one was taken (the newest snapshot in
  # backups/), and on macOS a run that closes Anki, backs up and reopens it
  # (backup-anki.rb). Elsewhere the page shows instructions instead.
  module Backup
    ROOT = File.expand_path('..', __dir__)
    SCRIPT = File.join(__dir__, 'backup-anki.rb')
    STEP = Steps::Step.new(id: 'backup', label: 'Back up', scripts: [], options: [])
    INSTRUCTIONS = 'To back up: close Anki, run ./backup-collection.sh in the repo, then reopen Anki.'

    module_function

    def automated?(host_os = RbConfig::CONFIG['host_os'])
      host_os.match?(/darwin/)
    end

    def last(dir = File.join(ROOT, 'backups'))
      Dir.glob(File.join(dir, 'collection-backup-*.anki2')).map { |f| File.mtime(f) }.max
    end

    def info
      { last: last&.iso8601, automated: automated?, instructions: INSTRUCTIONS }
    end

    # A plan the runner can run like any step's.
    def plan
      invocation = Command::Invocation.new(script_id: 'backup', argv: [RbConfig.ruby, SCRIPT, '--close-anki-and-back-up'])
      Command::Plan.new(step: STEP, deck: nil, dry_run: false, phase: nil, invocations: [invocation])
    end
  end
end
