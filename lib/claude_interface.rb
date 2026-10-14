require 'json'
require 'open3'
require_relative 'llm_interface'

class ClaudeInterface < LLMInterface
  # How `claude -p` reports a spent session/weekly allowance, e.g. "Claude AI
  # usage limit reached|1759338000" or "You've hit your limit · resets 3pm".
  # The CLI may print it as the response itself with a zero exit status, so
  # it's checked either way, but only on short output: a real response that
  # happens to mention a limit is long YAML.
  USAGE_LIMIT_PATTERN = /usage limit|hit your (?:\w+ )?limit|limit reached|out of (?:extra )?usage/i
  USAGE_LIMIT_MAX_LENGTH = 400

  def initialize(model: 'sonnet', verbose: false)
    super(model: model, verbose: verbose)
  end

  def verify_available!
    output, status = Open3.capture2('which', 'claude')
    unless status.success?
      raise NotFoundError, "Claude CLI not found in PATH. Install from: https://docs.claude.com/en/docs/claude-code"
    end
  end

  def generate(prompt)
    cmd = ['claude', '-p', '--model', @model, '--no-session-persistence']
    stdout_str, stderr_str, status = Open3.capture3(*cmd, stdin_data: prompt)

    [stdout_str, stderr_str].each do |text|
      if text.strip.length <= USAGE_LIMIT_MAX_LENGTH && text.match?(USAGE_LIMIT_PATTERN)
        raise UsageLimitError, text.strip
      end
    end

    unless status.success?
      raise APIError, "Claude CLI failed: #{stderr_str}"
    end

    print_verbose_output('claude', stdout_str)

    stdout_str
  end
end