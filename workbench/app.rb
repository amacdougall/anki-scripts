# frozen_string_literal: true

require 'date'
require 'json'
require 'sinatra/base'
require 'yaml'
require_relative 'backup'
require_relative 'command'
require_relative 'decks'
require_relative 'preferences'
require_relative 'runner'
require_relative 'steps'
require_relative 'summary'
require_relative '../lib/anki_connect'
require_relative '../lib/llm_config'

module Workbench
  # The Workbench's routes. The work happens in the scripts; this only builds
  # their command lines, runs them and reports on the decks.
  class App < Sinatra::Base
    ROOT = File.expand_path('..', __dir__)

    set :root, __dir__
    set :host_authorization, { permitted_hosts: %w[localhost 127.0.0.1] }
    set :show_exceptions, false
    set :raise_errors, false

    # Swappable in tests.
    set :decks, Decks.new
    set :preferences, Preferences.new
    set :runner, Runner.new
    # The sentences file's mtime when a run last wrote it to Anki, so the page
    # stops offering to write the same sentences again.
    set :sentences_written, {}
    set :anki_up, -> { AnkiConnect.new.version && true }

    helpers do
      def json(data, status = 200)
        content_type :json
        halt status, JSON.generate(data)
      end

      def body_params
        request.body.rewind
        data = JSON.parse(request.body.read)
        halt 400, JSON.generate(error: 'Expected a JSON object') unless data.is_a?(Hash)
        data
      rescue JSON::ParserError
        halt 400, JSON.generate(error: 'Expected JSON')
      end

      def decks
        settings.decks
      end

      def context
        all = decks.all
        Command::Context.new(decks: all['deck_names'], takoboto_decks: all['takoboto_decks'].map { |d| d['name'] })
      end

      def translation_notes
        Dir.glob('*.md', base: File.join(ROOT, 'prompts/translation')).map { |f| File.basename(f, '.md').unicode_normalize(:nfc) }
      end

      def summary(entry, all)
        Summary.for(entry, takoboto_decks: all['takoboto_decks'], translation_notes: translation_notes)
      end

      def plan_from(data)
        Command.build(data['step'], deck: data['deck'], values: data['options'], context: context,
                                    dry_run: data['dry_run'] == true, phase: data['phase'])
      end
    end

    SENTENCES_FILE = 'temp/example-sentences.yaml'

    error Runner::Busy do
      json({ error: env['sinatra.error'].message }, 409)
    end

    error Command::Invalid do
      json({ error: env['sinatra.error'].message }, 422)
    end

    error Decks::Error, AnkiConnect::Error do
      json({ error: env['sinatra.error'].message }, 503)
    end

    get '/' do
      erb :index
    end

    get '/api/status' do
      anki = begin
        settings.anki_up
      rescue AnkiConnect::Error, SystemCallError
        false
      end
      json(anki: anki)
    end

    # Every deck's counts, plus the page's summary of each (summary.rb);
    # empty_summary is for a deck with no Kaishi cards yet.
    get '/api/decks' do
      all = decks.all(refresh: params['refresh'] == '1')
      json(all.merge('summaries' => all['decks'].to_h { |d| [d['name'], summary(d, all)] },
                     'empty_summary' => summary(nil, all)))
    end

    # Re-counts one deck (after a run). entry is nil for a deck with no Kaishi cards.
    get '/api/decks/:name' do
      entry = decks.refresh(params['name'])
      json(entry: entry, summary: summary(entry, decks.all), takoboto_decks: decks.all['takoboto_decks'])
    end

    get '/api/config' do
      ctx = context
      steps = Steps::ALL.map do |step|
        files = step.options.select { |o| o.type == :file }.to_h { |o| [o.key, ctx.files(o.globs)] }
        step.to_h.merge(files: files)
      end
      json(steps: steps,
           llm: { default_provider: LlmConfig.default_provider,
                  providers: LlmConfig.providers.to_h { |p| [p, LlmConfig.models(p)] },
                  defaults: LlmConfig::TASKS.to_h { |t| [t, LlmConfig.providers.to_h { |p| [p, LlmConfig.default_model(t, p)] }] } },
           takoboto_decks: decks.all['takoboto_decks'],
           translation_notes: translation_notes,
           preferences: settings.preferences.all)
    end

    post '/api/preview' do
      plan = plan_from(body_params)
      json(commands: plan.displays, phase: plan.phase)
    end

    # The generated sentences waiting to be written: which deck they're for
    # and how many generated successfully.
    get '/api/sentences' do
      path = File.join(ROOT, SENTENCES_FILE)
      next json(path: SENTENCES_FILE, exists: false) unless File.exist?(path)

      data = YAML.safe_load_file(path, permitted_classes: [Date, Time]) || {}
      notes = data['notes'] || []
      json(path: SENTENCES_FILE, exists: true, deck: data.dig('metadata', 'target_deck'),
           ready: notes.count { |n| n['generation_status'] == 'success' }, total: notes.size,
           written: settings.sentences_written[:mtime] == File.mtime(path))
    rescue Psych::Exception => e
      json(path: SENTENCES_FILE, exists: true, error: "Can't read #{SENTENCES_FILE}: #{e.message}")
    end

    post '/api/runs' do
      data = body_params
      plan = plan_from(data)
      runner = settings.runner
      run = runner.start(plan) do |finished|
        next if finished.dry_run

        if finished.step_id == 'sentences' && finished.phase != 'generate' && finished.status == 'succeeded'
          path = File.join(ROOT, SENTENCES_FILE)
          settings.sentences_written[:mtime] = File.mtime(path) if File.exist?(path)
        end

        # Pulling from Takoboto also changes the source deck, so recount everything.
        finished.step_id == 'takoboto' ? decks.invalidate : decks.refresh(finished.deck)
      end
      settings.preferences.remember(plan.deck, plan.step, data['options'] || {}) unless plan.dry_run
      json(run.to_h, 201)
    end

    get '/api/backup' do
      json(Backup.info)
    end

    # macOS only: closes Anki, backs up and reopens it, as a run.
    post '/api/backup' do
      halt 422, JSON.generate(error: Backup::INSTRUCTIONS) unless Backup.automated?

      json(settings.runner.start(Backup.plan).to_h, 201)
    end

    # The run in progress, else the latest one, so a reloaded page can pick it up.
    get '/api/runs/current' do
      run = settings.runner.active || settings.runner.latest
      json(run: run&.to_h)
    end

    get '/api/runs/:id' do
      run = settings.runner.find(params['id']) or halt 404
      json(run.to_h)
    end

    post '/runs/:id/cancel' do
      run = settings.runner.find(params['id']) or halt 404
      json(cancelled: run.cancel)
    end

    # The run's output as Server-Sent Events: one "line" event per line (its
    # id is the line's index, so a reconnect resumes), then one "done" event
    # with the run's final state. Comments keep an idle connection alive.
    get '/runs/:id/events' do
      run = settings.runner.find(params['id']) or halt 404
      index = request.env['HTTP_LAST_EVENT_ID'].to_s.match?(/\A\d+\z/) ? request.env['HTTP_LAST_EVENT_ID'].to_i + 1 : 0
      content_type 'text/event-stream'
      cache_control :no_cache
      stream do |out|
        loop do
          lines, finished = run.wait_for_lines(index)
          lines.each do |line|
            out << "id: #{index}\nevent: line\ndata: #{JSON.generate(line)}\n\n"
            index += 1
          end
          break if finished && run.wait_for_lines(index, timeout: 0).first.empty?

          out << ": keep-alive\n\n" if lines.empty?
        end
        out << "event: done\ndata: #{JSON.generate(run.to_h)}\n\n"
      rescue IOError, Errno::EPIPE
        nil # the page went away; the run carries on
      end
    end
  end
end
