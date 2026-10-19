# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'tmpdir'
require_relative '../../workbench/app'

# The routes, with deck-status.rb, AnkiConnect and the runner stubbed: these
# tests never start a script.
class AppTest < Minitest::Test
  include Rack::Test::Methods

  STATUS = {
    'checks' => [{ 'key' => 'sentence', 'label' => 'Example sentence', 'script' => 'generate-sentences.rb' }],
    'decks' => [{ 'name' => '呪術廻戦', 'total' => 10, 'needs_work' => 4,
                  'counts' => { 'stray_html' => 0, 'sentence' => 4 } }],
    'takoboto_decks' => [{ 'name' => 'Takoboto Various', 'count' => 3 }]
  }.freeze

  # Records what it was asked to run.
  class FakeRunner
    FakeRun = Struct.new(:id, :plan) do
      def to_h
        { id: id, step: plan.step.id, commands: plan.displays, status: 'running' }
      end
    end

    attr_reader :plans

    def initialize
      @plans = []
      @busy = false
    end

    attr_writer :busy

    def start(plan)
      raise Workbench::Runner::Busy, 'Another run is still going' if @busy

      @plans << plan
      FakeRun.new('abc123', plan)
    end

    def find(_id) = nil
    def active = nil
    def latest = nil
  end

  def app
    Workbench::App
  end

  def default_host
    'localhost'
  end

  def setup
    @dir = Dir.mktmpdir
    @runner = FakeRunner.new
    status = ->(deck) { deck ? STATUS.merge('decks' => STATUS['decks'].select { |d| d['name'] == deck }) : STATUS }
    app.set :decks, Workbench::Decks.new(status: status, deck_names: -> { ['呪術廻戦', 'Kaishi 1.5k', 'Takoboto Various'] })
    app.set :preferences, Workbench::Preferences.new(File.join(@dir, 'prefs.yaml'))
    app.set :runner, @runner
    app.set :anki_up, -> { true }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post_json(path, data)
    post path, JSON.generate(data), 'CONTENT_TYPE' => 'application/json'
  end

  def body
    JSON.parse(last_response.body)
  end

  def test_page
    get '/'
    assert last_response.ok?
    assert_includes last_response.body, 'Kaishi Workbench'
  end

  def test_other_hosts_are_refused
    get '/api/status', {}, 'HTTP_HOST' => 'evil.example'
    assert_equal 403, last_response.status
  end

  def test_status
    get '/api/status'
    assert_equal({ 'anki' => true }, body)
  end

  def test_logs_when_anki_comes_and_goes
    log = StringIO.new
    Workbench::Log.io = log
    app.set :anki_was_up, nil
    get '/api/status'
    get '/api/status'
    app.set :anki_up, -> { raise AnkiConnect::NotRunningError, 'Cannot reach AnkiConnect' }
    get '/api/status'
    assert_equal({ 'anki' => false }, body)
    lines = log.string.lines.map { |l| l.sub(/\A\[[\d:]+\] /, '').chomp }
    assert_equal ['AnkiConnect is answering', "AnkiConnect isn't answering: Cannot reach AnkiConnect"], lines
  ensure
    Workbench::Log.io = nil
  end

  def test_decks_include_summaries
    get '/api/decks'
    assert last_response.ok?
    assert_equal ['呪術廻戦', 'Kaishi 1.5k', 'Takoboto Various'].sort, body['deck_names']
    assert_equal 'sentences', body['summaries']['呪術廻戦']['suggested']
    assert body['empty_summary']
  end

  def test_one_deck
    get "/api/decks/#{URI.encode_www_form_component('呪術廻戦')}"
    assert_equal 4, body['entry']['needs_work']
    assert_equal '4 missing', body['summary']['badges']['sentences']['text']
  end

  def test_decks_error_when_anki_is_down
    app.set :decks, Workbench::Decks.new(status: ->(_) { raise Workbench::Decks::Error, 'Cannot reach AnkiConnect' },
                                         deck_names: -> { [] })
    get '/api/decks'
    assert_equal 503, last_response.status
    assert_match(/AnkiConnect/, body['error'])
  end

  def test_config
    get '/api/config'
    steps = body['steps']
    assert_equal 'mined', steps.first['id']
    sentences = steps.find { |s| s['id'] == 'sentences' }
    assert_includes sentences['files']['instructions_file'], 'prompts/example-sentence-instructions.md'
    assert_equal 'claude', body['llm']['default_provider']
    assert_equal 'sonnet', body['llm']['defaults']['sentence_generation']['claude']
    assert_equal [{ 'name' => 'Takoboto Various', 'count' => 3 }], body['takoboto_decks']
  end

  def test_preview
    post_json '/api/preview', step: 'meanings', deck: '呪術廻戦', options: { 'limit' => '5' }, dry_run: true
    assert last_response.ok?
    assert_equal ["./add-meanings.rb --target-deck '呪術廻戦' --limit 5 --dry-run"], body['commands']
  end

  def test_preview_rejects_bad_values
    post_json '/api/preview', step: 'meanings', deck: '呪術廻戦', options: { 'limit' => 'lots' }
    assert_equal 422, last_response.status
    assert_match(/whole number/, body['error'])

    post_json '/api/preview', step: 'meanings', deck: 'Nope', options: {}
    assert_equal 422, last_response.status
  end

  def test_bad_json
    post '/api/preview', 'not json', 'CONTENT_TYPE' => 'application/json'
    assert_equal 400, last_response.status
  end

  def test_start_a_run
    post_json '/api/runs', step: 'sentences', deck: '呪術廻戦',
                           options: { 'provider' => 'opencode', 'instructions_file' => 'prompts/example-sentence-instructions.md' }
    assert_equal 201, last_response.status
    assert_equal 'abc123', body['id']
    plan = @runner.plans.last
    assert_equal 'generate', plan.phase
    assert_equal({ '呪術廻戦' => { 'sentences' => { 'provider' => 'opencode',
                                                    'instructions_file' => 'prompts/example-sentence-instructions.md' } } },
                 app.preferences.all, 'remembers the provider and prompt for the deck')
  end

  def test_dry_runs_are_not_remembered
    post_json '/api/runs', step: 'meanings', deck: '呪術廻戦', options: { 'provider' => 'google' }, dry_run: true
    assert_equal 201, last_response.status
    assert_empty app.preferences.all
  end

  def test_second_run_is_refused
    @runner.busy = true
    post_json '/api/runs', step: 'strip_html', deck: '呪術廻戦', options: {}
    assert_equal 409, last_response.status
  end

  def test_unknown_run
    get '/runs/nope/events'
    assert_equal 404, last_response.status
    post '/runs/nope/cancel'
    assert_equal 404, last_response.status
  end

  def test_backup_info
    get '/api/backup'
    assert_includes body.keys, 'last'
  end

  def test_backup_needs_anki_closed
    post '/api/backup'
    assert_equal 409, last_response.status
    assert_match(/Close Anki first/, body['error'])
    assert_empty @runner.plans

    app.set :anki_up, -> { false }
    post '/api/backup'
    assert_equal 201, last_response.status
    assert_equal ['./backup-collection.sh'], @runner.plans.last.displays
  end
end
