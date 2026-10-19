# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require_relative '../../workbench/command'

class CommandTest < Minitest::Test
  Command = Workbench::Command

  def setup
    @root = Dir.mktmpdir
    %w[temp prompts prompts/local].each { |dir| FileUtils.mkdir_p(File.join(@root, dir)) }
    %w[temp/words-a.yaml prompts/example-sentence-instructions.md prompts/local/jjk.md].each do |file|
      File.write(File.join(@root, file), '')
    end
    @context = Command::Context.new(decks: ['呪術廻戦', 'とらドラ！', 'Kaishi 1.5k', 'Takoboto Various'],
                                    takoboto_decks: ['Takoboto Various'], root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def build(step, deck: '呪術廻戦', values: {}, **opts)
    Command.build(step, deck: deck, values: values, context: @context, **opts)
  end

  def args(plan, index = 0)
    plan.invocations[index].argv[2..]
  end

  def test_argv_runs_the_script_with_this_ruby
    argv = build('strip_html').invocations.first.argv
    assert_equal RbConfig.ruby, argv[0]
    assert_equal File.join(@root, 'strip-word-html.rb'), argv[1]
    assert_equal ['--target-deck', '呪術廻戦'], argv[2..]
  end

  def test_display_quotes_like_a_shell
    plan = build('strip_html', deck: 'とらドラ！', values: { 'limit' => '5' }, dry_run: true)
    assert_equal ["./strip-word-html.rb --target-deck 'とらドラ！' --limit 5 --dry-run"], plan.displays
    assert_equal %q('it'\''s'), Command.quote("it's")
  end

  def test_defaults_are_left_out
    plan = build('furigana', values: { 'provider' => 'claude', 'model' => 'sonnet', 'review' => true,
                                       'review_unreviewed' => false, 'force' => false })
    assert_equal ['--target-deck', '呪術廻戦'], args(plan)
  end

  def test_flags_toggles_and_numbers
    plan = build('furigana', values: { 'review' => false, 'review_unreviewed' => 'true', 'force' => true,
                                       'review_jobs' => '2', 'limit' => '10' })
    assert_equal ['--target-deck', '呪術廻戦', '--review-jobs', '2', '--limit', '10', '--no-review',
                  '--review-unreviewed', '--force'], args(plan)
  end

  def test_provider_and_model
    plan = build('meanings', values: { 'provider' => 'opencode', 'model' => 'opencode/kimi-k2.6' })
    assert_equal ['--target-deck', '呪術廻戦', '--provider', 'opencode', '--model', 'opencode/kimi-k2.6'], args(plan)

    plan = build('meanings', values: { 'provider' => 'opencode', 'model' => 'opencode/deepseek-v4.1-flash' })
    assert_equal ['--target-deck', '呪術廻戦', '--provider', 'opencode'], args(plan), 'the task default is left out'

    plan = build('meanings', values: { 'provider' => 'google' })
    assert_equal ['--target-deck', '呪術廻戦', '--provider', 'google'], args(plan)
  end

  def test_choice_with_its_own_flags
    assert_equal ['--word-only'], args(build('audio', values: { 'clips' => 'word' }))[2..]
    assert_equal [], args(build('audio', values: { 'clips' => 'both' }))[2..]
    assert_equal ['--model', 'gemini-3.8-flash-tts'], args(build('audio', values: { 'model' => 'gemini-3.8-flash-tts' }))[2..]
  end

  def test_takoboto_always_passes_source_and_cleanup
    plan = build('takoboto', values: { 'source_deck' => 'Takoboto Various' })
    assert_equal ['--target-deck', '呪術廻戦', '--source-deck', 'Takoboto Various', '--cleanup', 'x'], args(plan)
  end

  def test_word_list_file_is_positional
    plan = build('word_list', values: { 'file' => 'temp/words-a.yaml' }, dry_run: true)
    assert_equal ['--target-deck', '呪術廻戦', 'temp/words-a.yaml', '--dry-run'], args(plan)
  end

  def test_sentences_runs_three_scripts
    plan = build('sentences', values: { 'pause' => false, 'include_existing' => true, 'limit' => '3',
                                        'instructions_file' => 'prompts/local/jjk.md' })
    assert_equal 'all', plan.phase
    assert_equal %w[extract generate write], plan.invocations.map(&:script_id)
    assert_equal ['--target-deck', '呪術廻戦', '--force'], args(plan, 0)
    assert_equal ['--instructions-file', 'prompts/local/jjk.md', '--limit', '3'], args(plan, 1)
    assert_equal ['--target-deck', '呪術廻戦'], args(plan, 2)
  end

  def test_sentences_pause_and_write_phases
    assert_equal %w[extract generate], build('sentences').invocations.map(&:script_id), 'pause is on by default'
    assert_equal %w[write], build('sentences', phase: 'write').invocations.map(&:script_id)

    dry = build('sentences', dry_run: true)
    assert_equal 'write', dry.phase
    assert_equal ['--target-deck', '呪術廻戦', '--dry-run'], args(dry)
  end

  def test_rejects_bad_decks
    assert_invalid(/Choose a target deck/) { build('strip_html', deck: '') }
    assert_invalid(/No such deck/) { build('strip_html', deck: 'Nope') }
    assert_invalid(/curated/) { build('strip_html', deck: 'Kaishi 1.5k') }
  end

  def test_rejects_unknown_steps_and_options
    assert_invalid(/Unknown step/) { build('rm-rf') }
    assert_invalid(/nothing to run/) { build('mined') }
    assert_invalid(/no option --exec/) { build('strip_html', values: { '--exec' => 'x' }) }
    assert_invalid(/no dry run/) { build('takoboto', values: { 'source_deck' => 'Takoboto Various' }, dry_run: true) }
    assert_invalid(/Unknown phase/) { build('sentences', phase: 'everything') }
  end

  def test_rejects_bad_values
    assert_invalid(/whole number/) { build('strip_html', values: { 'limit' => '-1' }) }
    assert_invalid(/whole number/) { build('strip_html', values: { 'limit' => '5; rm -rf /' }) }
    assert_invalid(/whole number/) { build('strip_html', values: { 'limit' => '0' }) }
    assert_invalid(/true or false/) { build('meanings', values: { 'force' => 'yes please' }) }
    assert_invalid(/unknown provider/) { build('furigana', values: { 'provider' => 'google' }) }
    assert_invalid(/isn't listed/) { build('meanings', values: { 'model' => 'gpt-9' }) }
    assert_invalid(/doesn't apply/) { build('meanings', values: { 'provider' => 'google', 'model' => 'haiku' }) }
    assert_invalid(/unknown choice/) { build('audio', values: { 'clips' => 'all' }) }
    assert_invalid(/unknown choice/) { build('audio', values: { 'model' => '--force' }) }
  end

  def test_rejects_files_outside_the_offered_ones
    assert_invalid(/required/) { build('word_list') }
    assert_invalid(/isn't one of the files/) { build('word_list', values: { 'file' => '../secrets.yaml' }) }
    assert_invalid(/isn't one of the files/) { build('word_list', values: { 'file' => '/etc/passwd' }) }
    assert_invalid(/isn't one of the files/) do
      build('sentences', values: { 'instructions_file' => 'temp/words-a.yaml' })
    end
  end

  def test_rejects_source_decks_without_takoboto_notes
    assert_invalid(/required/) { build('takoboto') }
    assert_invalid(/holds no Takoboto notes/) { build('takoboto', values: { 'source_deck' => 'とらドラ！' }) }
  end

  def assert_invalid(pattern, &block)
    error = assert_raises(Command::Invalid, &block)
    assert_match pattern, error.message
  end
end
