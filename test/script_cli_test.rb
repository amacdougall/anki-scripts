# frozen_string_literal: true

require 'test_helper'
require 'script_cli'

class ScriptCLITest < Minitest::Test
  def cli(deck: :required)
    ScriptCLI.new('test.rb', 'Does a thing.', deck: deck).tap do |c|
      c.dry_run
      c.limit
      c.force('Redo it')
    end
  end

  # Runs parse! and returns the exit status it ended with.
  def exit_status(cli, argv)
    error = assert_raises(SystemExit) { capture_io { cli.parse!(argv) } }
    error.status
  end

  def test_standard_flags
    options = cli.parse!(%w[-d 呪術廻戦 --dry-run --limit 5 --force])
    assert_equal '呪術廻戦', options[:target_deck]
    assert options[:dry_run]
    assert_equal 5, options[:limit]
    assert options[:force]
  end

  def test_target_deck_is_required
    assert_equal ScriptCLI::EXIT_USAGE, exit_status(cli, [])
    assert_equal ScriptCLI::EXIT_USAGE, exit_status(cli, ['--target-deck', ' '])
  end

  def test_optional_target_deck
    assert_nil cli(deck: :optional).parse!([])[:target_deck]
  end

  def test_curated_deck_is_refused
    assert_equal ScriptCLI::EXIT_USAGE, exit_status(cli, ['-d', 'Kaishi 1.5k'])
  end

  def test_unknown_flag_is_a_usage_error
    assert_equal ScriptCLI::EXIT_USAGE, exit_status(cli, %w[-d x --bogus])
  end

  def test_help_exits_ok
    assert_equal ScriptCLI::EXIT_OK, exit_status(cli, ['-h'])
  end

  def test_llm_defaults_to_config
    c = cli.tap { |x| x.llm(:furigana_review, providers: %w[claude opencode]) }
    options = c.parse!(%w[-d x])
    assert_equal LlmConfig.default_provider, options[:provider]
    assert_equal LlmConfig.default_model(:furigana_review, options[:provider]), options[:model]
  end

  def test_llm_model_follows_provider
    c = cli.tap { |x| x.llm(:sentence_translation) }
    options = c.parse!(%w[-d x --provider opencode])
    assert_equal LlmConfig.default_model(:sentence_translation, 'opencode'), options[:model]
  end

  def test_llm_explicit_model
    c = cli.tap { |x| x.llm(:sentence_translation) }
    assert_equal 'opus', c.parse!(%w[-d x -m opus])[:model]
  end

  def test_llm_rejects_unlisted_provider
    c = cli.tap { |x| x.llm(:sentence_translation, providers: %w[claude opencode]) }
    assert_equal ScriptCLI::EXIT_USAGE, exit_status(c, %w[-d x --provider google])
  end

  def test_google_has_no_model
    c = cli.tap { |x| x.llm(:word_meaning, providers: %w[claude opencode google]) }
    assert_nil c.parse!(%w[-d x --provider google])[:model]
    c = cli.tap { |x| x.llm(:word_meaning, providers: %w[claude opencode google]) }
    assert_equal ScriptCLI::EXIT_USAGE, exit_status(c, %w[-d x --provider google -m sonnet])
  end
end
