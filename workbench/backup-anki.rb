#!/usr/bin/env ruby
# frozen_string_literal: true

# The Workbench's Back up button (macOS): closes Anki, runs
# backup-collection.sh (which needs Anki closed so the collection is flushed),
# then reopens Anki and waits for AnkiConnect. Anki is asked to close through
# AnkiConnect's guiExitAnki, which closes the collection properly (and syncs, if
# Anki is set to sync on close).

$stdout.sync = true

require 'net/http'
require 'optparse'
require_relative '../lib/anki_connect'

# Closing Anki is disruptive, so nothing happens without the explicit flag.
confirmed = false
OptionParser.new do |opts|
  opts.banner = 'Usage: workbench/backup-anki.rb --close-anki-and-back-up'
  opts.separator ''
  opts.separator 'Closes Anki, runs backup-collection.sh, then reopens Anki (macOS). Used by the Workbench.'
  opts.separator ''
  opts.on('--close-anki-and-back-up', 'Do it (required)') { confirmed = true }
  opts.on('-h', '--help', '-?', 'Show this message') do
    puts opts
    exit 0
  end
end.parse!
abort 'Nothing done: pass --close-anki-and-back-up to close Anki and back up.' unless confirmed

ROOT = File.expand_path('..', __dir__)
# The Anki process, whether started by the launcher (a Python venv running aqt)
# or from an older app bundle.
ANKI_PROCESS = 'aqt\.run\(\)|Anki\.app/Contents/MacOS/'
QUIT_TIMEOUT = 120 # seconds; closing can include a sync
START_TIMEOUT = 120

def anki_process?
  system('pgrep', '-f', ANKI_PROCESS, out: File::NULL, err: File::NULL)
end

def connect_up?
  AnkiConnect.new.version
  true
rescue AnkiConnect::Error, SystemCallError, Net::ReadTimeout
  false
end

def wait_until(timeout)
  deadline = Time.now + timeout
  until yield
    return false if Time.now > deadline

    sleep 1
  end
  true
end

was_running = anki_process?
if was_running
  puts 'Asking Anki to close (it may sync first)…'
  begin
    AnkiConnect.new.gui_exit
  rescue AnkiConnect::Error, SystemCallError => e
    puts "[X] Error: couldn't ask Anki to close: #{e.message}. Close Anki yourself and try again."
    exit 1
  end
  unless wait_until(QUIT_TIMEOUT) { !anki_process? }
    puts "[X] Error: Anki is still running after #{QUIT_TIMEOUT} s. Close it yourself and try again."
    exit 1
  end
  puts '[+] Anki closed'
else
  puts 'Anki isn’t running.'
end

ok = system(File.join(ROOT, 'backup-collection.sh'), chdir: ROOT)
puts(ok ? '[+] Backed up the collection' : '[X] Error: backup-collection.sh failed')

if was_running
  puts 'Reopening Anki…'
  system('open', '-a', 'Anki')
  if wait_until(START_TIMEOUT) { connect_up? }
    puts '[+] Anki is back and AnkiConnect is answering'
  else
    puts "[!] Warning: AnkiConnect didn't answer within #{START_TIMEOUT} s. Check that Anki opened (and pick a profile if it asks)."
  end
end

exit(ok ? 0 : 1)
