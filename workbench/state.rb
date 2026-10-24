# frozen_string_literal: true

require 'time'
require 'yaml'

module Workbench
  # Facts the Workbench keeps between sessions (not choices, which go in
  # preferences.rb), in a gitignored YAML file:
  #
  #   last_backup: '2026-10-21T14:03:12+09:00'
  class State
    PATH = File.expand_path('../config/workbench.state.yaml', __dir__)

    def initialize(path = PATH)
      @path = path
      @mutex = Mutex.new
    end

    def last_backup
      value = @mutex.synchronize { load['last_backup'] }
      value && Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def last_backup=(time)
      set('last_backup', time.iso8601)
    end

    private

    def set(key, value)
      @mutex.synchronize do
        data = load
        data[key] = value
        File.write(@path, YAML.dump(data))
      end
    end

    def load
      File.exist?(@path) ? (YAML.safe_load_file(@path) || {}) : {}
    end
  end
end
