require 'open3'

class LLMInterface
  class NotFoundError < StandardError; end
  class APIError < StandardError; end
  # The account's usage allowance is spent (e.g. a Claude session limit).
  # Deliberately not an APIError, so retry loops don't retry it: callers should
  # stop and let the user resume once the limit resets.
  class UsageLimitError < StandardError; end

  def initialize(model:, verbose: false)
    @model = model
    @verbose = verbose
    verify_available!
  end

  def generate(prompt)
    raise NotImplementedError, "#{self.class}#generate must be implemented"
  end

  def verify_available!
    raise NotImplementedError, "#{self.class}#verify_available! must be implemented"
  end

  private

  def print_verbose_output(label, text)
    return unless @verbose

    puts "\n\e[2m--- #{label} response ---\e[0m"
    puts text
    puts "\e[2m--- end response ---\e[0m"
  end
end