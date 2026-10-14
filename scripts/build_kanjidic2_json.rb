#!/usr/bin/env ruby

# Converts KANJIDIC2 XML into a simplified JSON mapping
# of kanji → readings (hiragana). Downloads the XML if not present.
#
# Usage: ruby scripts/build_kanjidic2_json.rb (bootstrap.rb runs it for you)
#
# Output: data/kanjidic2_readings.json

require 'rexml/document'
require 'json'
require 'open-uri'
require 'zlib'
require 'fileutils'

DATA_DIR = File.expand_path('../data', __dir__)
OUTPUT_PATH = File.join(DATA_DIR, 'kanjidic2_readings.json')
XML_URL = 'https://www.edrdg.org/kanjidic/kanjidic2.xml.gz'
XML_GZ_PATH = File.join(DATA_DIR, 'kanjidic2.xml.gz')
XML_PATH = File.join(DATA_DIR, 'kanjidic2.xml')

def katakana_to_hiragana(text)
  text.chars.map do |char|
    code = char.ord
    if code >= 0x30A1 && code <= 0x30F6
      (code - 0x30A1 + 0x3041).chr('UTF-8')
    else
      char
    end
  end.join
end

# Download if needed
unless File.exist?(XML_PATH)
  unless File.exist?(XML_GZ_PATH)
    puts "Downloading KANJIDIC2 XML..."
    URI.open(XML_URL) do |gz_stream|
      File.open(XML_GZ_PATH, 'wb') do |file|
        file.write(gz_stream.read)
      end
    end
    puts "Downloaded to #{XML_GZ_PATH}"
  end

  puts "Decompressing..."
  Zlib::GzipReader.open(XML_GZ_PATH) do |gz|
    File.open(XML_PATH, 'w') do |file|
      file.write(gz.read)
    end
  end
  puts "Decompressed to #{XML_PATH}"
end

puts "Parsing KANJIDIC2 XML (this may take a moment)..."
doc = REXML::Document.new(File.read(XML_PATH))

readings_map = {}
count = 0

doc.elements.each('kanjidic2/character') do |char_elem|
  literal = char_elem.elements['literal'].text
  readings = []

  char_elem.elements.each('reading_meaning/rmgroup/reading') do |reading_elem|
    r_type = reading_elem.attributes['r_type']
    next unless r_type == 'ja_on' || r_type == 'ja_kun'

    reading = reading_elem.text

    if r_type == 'ja_kun'
      # Strip okurigana: "き.る" → "き", "きれ.る" → "きれ"
      reading = reading.split('.').first
      # Also strip any trailing dash (some entries have e.g. "き-")
      reading = reading.gsub('-', '')
    end

    # Convert to hiragana (on'yomi are in katakana)
    reading = katakana_to_hiragana(reading)

    readings << reading unless reading.empty?
  end

  readings.uniq!

  if readings.any?
    readings_map[literal] = readings
    count += 1
  end
end

FileUtils.mkdir_p(DATA_DIR)
File.write(OUTPUT_PATH, JSON.pretty_generate(readings_map))

puts "Wrote #{count} kanji entries to #{OUTPUT_PATH}"
puts "File size: #{(File.size(OUTPUT_PATH) / 1024.0).round(1)} KB"

# Clean up XML files
File.delete(XML_GZ_PATH) if File.exist?(XML_GZ_PATH)
File.delete(XML_PATH) if File.exist?(XML_PATH)
puts "Cleaned up temporary XML files."
