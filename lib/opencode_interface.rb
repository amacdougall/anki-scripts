require 'json'
require 'open3'
require_relative 'llm_interface'

class OpenCodeInterface < LLMInterface
  # Running cost of every request made through OpenCode in this process (USD,
  # as reported by `opencode run --format json`), printed when the script
  # exits. Shared across instances and threads.
  @cost_mutex = Mutex.new
  @total_cost = 0.0
  @requests = 0

  class << self
    attr_reader :total_cost, :requests

    def record(cost)
      @cost_mutex.synchronize do
        @total_cost += cost
        @requests += 1
      end
    end
  end

  at_exit do
    if OpenCodeInterface.requests > 0
      count = OpenCodeInterface.requests
      puts format('OpenCode cost: $%.4f (%d %s)', OpenCodeInterface.total_cost, count, count == 1 ? 'request' : 'requests')
    end
  end

  def verify_available!
    output, status = Open3.capture2('which', 'opencode')
    unless status.success?
      raise NotFoundError, "opencode CLI not found in PATH. Install from: https://opencode.ai"
    end
  end

  # Returns the model's reply text. Requests JSON events so the reply comes
  # back without OpenCode's formatting, along with the request's cost.
  def generate(prompt)
    cmd = ['opencode', 'run', '-m', @model, '--format', 'json', '--dangerously-skip-permissions']
    stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: prompt)

    unless status.success?
      # With --format json, API errors arrive as an `error` event on stdout
      # and stderr is empty.
      raise APIError, "opencode run failed: #{error_message(stdout_str) || stderr_str}"
    end

    text, cost = parse_events(stdout_str)
    self.class.record(cost)
    print_verbose_output('opencode', text)

    text
  end

  private

  # Joins the `text` parts of the JSON event stream and sums the `cost` of its
  # `step_finish` events. Lines that aren't JSON are kept as text, so output
  # from an older OpenCode without --format json still gets through.
  def parse_events(stdout_str)
    texts = []
    cost = 0.0
    stdout_str.each_line do |line|
      event = JSON.parse(line)
      part = event['part'] || {}
      case event['type']
      when 'text' then texts << part['text'].to_s
      when 'step_finish' then cost += part['cost'].to_f
      end
    rescue JSON::ParserError
      texts << line
    end
    [texts.join, cost]
  end

  # The message of the first `error` event in the JSON event stream, if any.
  def error_message(stdout_str)
    stdout_str.each_line do |line|
      event = JSON.parse(line)
      next unless event['type'] == 'error'

      error = event['error'] || {}
      return error.dig('data', 'message') || error['name'] || line.strip
    rescue JSON::ParserError
      next
    end
    nil
  end
end
