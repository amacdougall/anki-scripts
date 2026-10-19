#!/usr/bin/env ruby
# frozen_string_literal: true

# Starts the Workbench, a local web page that runs this repo's scripts against
# one deck at a time and shows what each deck still needs. Listens on
# 127.0.0.1 only, then opens the page in a browser.
#
#   ./workbench.rb [--port 4567] [--no-open]

$stdout.sync = true

require 'optparse'
require 'rbconfig'

options = { port: 4567, open: true }
OptionParser.new do |opts|
  opts.banner = 'Usage: workbench.rb [options]'
  opts.separator ''
  opts.separator 'Starts the Workbench at http://localhost:PORT (this machine only).'
  opts.separator ''
  opts.separator 'Options:'
  opts.on('--port PORT', Integer, "Port to listen on (default: #{options[:port]})") { |p| options[:port] = p }
  opts.on('--[no-]open', 'Open the page in a browser (default: on)') { |o| options[:open] = o }
  opts.on('-h', '--help', '-?', 'Show this message') do
    puts opts
    exit 0
  end
end.parse!

begin
  require 'bundler/setup'
  Bundler.require(:workbench)
rescue LoadError, Bundler::GemNotFound => e
  warn "Error: the Workbench gems aren't installed (#{e.message})."
  warn 'Run `bundle install` and try again.'
  exit 1
end

require_relative 'workbench/app'

url = "http://localhost:#{options[:port]}/"

Workbench::App.on_start do
  puts "Workbench running at #{url} (Ctrl-C to stop)"
  next unless options[:open]

  opener = case RbConfig::CONFIG['host_os']
           when /darwin/ then 'open'
           when /linux|bsd/ then 'xdg-open'
           end
  if opener && system(opener, url, out: File::NULL, err: File::NULL)
    nil
  else
    puts "Open #{url} in a browser."
  end
end

Workbench::App.set :environment, :production
Workbench::App.set :server, :puma
Workbench::App.set :server_settings, { Threads: '1:16', Silent: true }
begin
  Workbench::App.run!(bind: '127.0.0.1', port: options[:port], quiet: true)
rescue Errno::EADDRINUSE
  warn "Error: port #{options[:port]} is in use (is the Workbench already running?). Try --port."
  exit 1
end
