source 'https://rubygems.org'
ruby '>= 3.4'

# Used by the inlined Gemini TTS client (lib/gemini_tts/).
gem 'faraday', '>= 2.0', '< 3'

# Standard-library gems that Ruby 3.4 no longer loads by default under Bundler.
gem 'base64' # lib/gemini_tts/
gem 'csv' # lib/pitch_database.rb
gem 'rexml' # scripts/build_kanjidic2_json.rb

# The Workbench (workbench.rb), a local web UI for the scripts.
group :workbench do
  gem 'puma', '~> 7.0'
  gem 'rackup', '~> 2.2'
  gem 'sinatra', '~> 4.1'
end

group :test do
  gem 'minitest', '~> 5.25'
  gem 'rack-test', '~> 2.2'
  gem 'rake', '~> 13.0'
end
