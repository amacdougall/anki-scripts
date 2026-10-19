# frozen_string_literal: true

require_relative 'command'
require_relative 'steps'

module Workbench
  # Collection backups. backup-collection.sh needs Anki closed (so the
  # collection is flushed), and closing and reopening Anki is left to the
  # person: the Back up button only runs the script once AnkiConnect has
  # stopped answering. The last backup is the newest snapshot in backups/.
  module Backup
    ROOT = File.expand_path('..', __dir__)
    SCRIPT = File.join(ROOT, 'backup-collection.sh')
    STEP = Steps::Step.new(id: 'backup', label: 'Back up', scripts: [], options: [])
    CLOSE_FIRST = 'Close Anki first (so the collection is saved), then click Back up again. Reopen Anki afterward.'

    module_function

    def last(dir = File.join(ROOT, 'backups'))
      Dir.glob(File.join(dir, 'collection-backup-*.anki2')).map { |f| File.mtime(f) }.max
    end

    def info
      { last: last&.iso8601 }
    end

    # A plan the runner can run like any step's.
    def plan
      invocation = Command::Invocation.new(script_id: 'backup', argv: [SCRIPT])
      Command::Plan.new(step: STEP, deck: nil, dry_run: false, phase: nil, invocations: [invocation])
    end
  end
end
