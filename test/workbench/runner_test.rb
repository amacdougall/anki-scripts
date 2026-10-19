# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require_relative '../../workbench/runner'
require_relative '../../workbench/command'

# Runs tiny Ruby one-liners in place of the scripts: nothing here talks to Anki.
class RunnerTest < Minitest::Test
  Command = Workbench::Command
  Runner = Workbench::Runner

  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, 'workbench.log')
    @runner = Runner.new(log_path: @log, root: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def plan(*scripts, step: 'strip_html', dry_run: false)
    invocations = scripts.each_with_index.map do |code, i|
      path = File.join(@dir, "script#{i}.rb")
      File.write(path, "$stdout.sync = true\n#{code}\n")
      Command::Invocation.new(script_id: "s#{i}", argv: [RbConfig.ruby, path])
    end
    Command::Plan.new(step: Workbench::Steps.find(step), deck: '呪術廻戦', dry_run: dry_run, phase: nil,
                      invocations: invocations)
  end

  def finish(run, timeout: 10)
    deadline = Time.now + timeout
    sleep 0.02 until run.finished? || Time.now > deadline
    assert run.finished?, 'run did not finish'
    sleep 0.02 while @runner.active # the runner clears it just after
    run.wait_for_lines(0, timeout: 0).first.map { |l| l[:text] }
  end

  def test_streams_output_and_succeeds
    finished = nil
    run = @runner.start(plan("puts 'one'; warn 'two'; puts \"\\e[2mthree\\e[0m\"")) { |r| finished = r }
    lines = finish(run)
    assert_equal ['$ ./script0.rb', 'one', 'two', 'three'], lines
    assert_equal 'succeeded', run.status
    assert_equal 0, run.to_h[:exit_code]
    assert_same run, finished
    assert_includes File.read(@log), 'strip_html 呪術廻戦: succeeded'
  end

  def test_exit_statuses
    { 1 => 'failed', 2 => 'usage_error', 3 => 'limit', 9 => 'failed' }.each do |code, status|
      run = @runner.start(plan("exit #{code}"))
      finish(run)
      assert_equal status, run.status, "exit #{code}"
      assert_equal code, run.to_h[:exit_code]
    end
  end

  def test_stops_at_the_first_failure
    run = @runner.start(plan("puts 'a'", 'exit 3', "puts 'never'"))
    lines = finish(run)
    assert_equal ['$ ./script0.rb', 'a', '$ ./script1.rb'], lines
    assert_equal 'limit', run.status
  end

  def test_one_run_at_a_time
    run = @runner.start(plan('sleep 0.5'))
    assert_raises(Runner::Busy) { @runner.start(plan("puts 'x'")) }
    finish(run)
    finish(@runner.start(plan("puts 'x'")))
  end

  def test_cancel_interrupts_the_script
    run = @runner.start(plan("puts 'started'; sleep 10; puts 'not reached'"))
    sleep 0.05 until run.wait_for_lines(0, timeout: 0).first.size >= 2
    assert run.cancel
    lines = finish(run)
    assert_equal 'cancelled', run.status
    refute_includes lines, 'not reached'
    refute run.cancel, 'nothing left to cancel'
  end

  def test_wait_for_lines_resumes_from_an_index
    run = @runner.start(plan("puts 'a'; puts 'b'"))
    finish(run)
    lines, done = run.wait_for_lines(2, timeout: 0)
    assert_equal ['b'], lines.map { |l| l[:text] }
    assert done
  end

  def test_scripts_get_no_stdin
    run = @runner.start(plan("p $stdin.gets"))
    assert_includes finish(run), 'nil'
  end
end
