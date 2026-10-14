module ProgressReporter
  def self.start(message)
    puts message
    puts ""
  end

  def self.progress(current, total, message = nil)
    prefix = "[#{current}/#{total}]"
    if message
      puts "#{prefix} #{message}"
    else
      puts prefix
    end
  end

  def self.success(message)
    puts "[+] #{message}"
  end

  def self.warning(message)
    puts "[!] Warning: #{message}"
  end

  def self.error(message)
    puts "[X] Error: #{message}"
  end

  def self.summary(stats)
    puts ""
    puts "=" * 50
    puts "SUMMARY"
    puts "=" * 50
    puts "  Notes processed:       #{stats[:total]}"
    puts "  Successfully updated:  #{stats[:updated]}"
    puts "  Skipped:               #{stats[:skipped]}"
    puts "  Errors:                #{stats[:errors]}"
    puts "=" * 50
  end
end
