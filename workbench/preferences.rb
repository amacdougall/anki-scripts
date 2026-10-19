# frozen_string_literal: true

require 'yaml'
require_relative 'steps'

module Workbench
  # Option choices remembered per deck between sessions (the options marked
  # `remember` in steps.rb: provider, model, prompt file), in a gitignored YAML
  # file:
  #
  #   呪術廻戦:
  #     sentences:
  #       instructions_file: prompts/local/example-sentence-instructions-jujutsu-kaisen.md
  class Preferences
    PATH = File.expand_path('../config/workbench.local.yaml', __dir__)

    def initialize(path = PATH)
      @path = path
      @mutex = Mutex.new
    end

    def all
      @mutex.synchronize { load }
    end

    # Saves the remembered options among values for a deck's step; a blank
    # value forgets that option.
    def remember(deck, step, values)
      keys = step.options.select(&:remember).map(&:key)
      return if keys.empty?

      @mutex.synchronize do
        data = load
        saved = (data.dig(deck, step.id) || {}).merge(values.slice(*keys).transform_values(&:to_s))
        saved.reject! { |_, v| v.strip.empty? }
        (data[deck] ||= {})[step.id] = saved
        File.write(@path, YAML.dump(data))
      end
    end

    private

    def load
      File.exist?(@path) ? (YAML.safe_load_file(@path) || {}) : {}
    end
  end
end
