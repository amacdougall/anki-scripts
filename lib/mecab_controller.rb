require 'open3'
require_relative 'kanji_reading_resolver'
require_relative 'unidic'

class MecabController
  # Path to MeCab support directory (local copy): the MeCab binaries and an
  # empty mecabrc. The dictionary is UniDic (see lib/unidic.rb), not the IPADIC
  # sys.dic that also lives here.
  MECAB_SUPPORT_DIR = File.expand_path('../support/mecab', __dir__)

  # Unicode character used to replace ASCII Space (0x20) in expression before
  # passing in to MeCab. MeCab separates kanji/reading nodes with ASCII spaces.
  ASCII_SPACE_TOKEN = "\u{FFFF}"

  # Field format arguments for MeCab: each token as surface[kana reading].
  MECAB_ARGS = [
    "--node-format=%m[%f[#{UniDic::KANA_FEATURE}]] ",
    '--eos-format=\n',
    '--unk-format=%m[] '
  ]

  # Format arguments for #tokens: surface, then the two part-of-speech levels;
  # a bare EOS line ends each input line.
  TOKEN_ARGS = [
    "--node-format=%m\t%f[0]\t%f[1]\n",
    "--eos-format=EOS\n",
    "--unk-format=%m\t\t\n"
  ]

  def initialize
    UniDic.ensure_installed!
    @mecab_cmd = build_mecab_command
    @tokens_cmd = build_mecab_command(TOKEN_ARGS)
    @reading_resolver = KanjiReadingResolver.new
  end

  # Generate furigana in bracket notation for the given text.
  # When preferred_reading is given and MeCab's combined reading matches,
  # MeCab's per-token splitting is preserved. When it differs, falls back to
  # direct kanji/reading alignment using the preferred reading.
  # Returns text with furigana like: 漢字[かんじ]
  def generate_furigana(text, ignore_numbers: true, preferred_reading: nil)
    return "" if text.nil? || text.strip.empty?

    # Prepare text for MeCab
    processed_text = text.gsub(' ', ASCII_SPACE_TOKEN)

    # Run MeCab
    stdout, stderr, status = Open3.capture3(
      *@mecab_cmd,
      stdin_data: processed_text + "\n",
      chdir: MECAB_SUPPORT_DIR
    )

    unless status.success?
      raise "MeCab failed: #{stderr}"
    end

    # Parse MeCab output
    nodes = parse_mecab_output(stdout.strip, ignore_numbers: ignore_numbers)

    # When a preferred reading is provided, check whether MeCab's combined
    # reading already matches. If it does, keep MeCab's per-token splitting.
    # If not, fall back to building furigana directly from the whole word.
    # Normalize to hiragana for comparison since katakana/hiragana choice is
    # stylistic, but preserve the original form in the output.
    if preferred_reading && !preferred_reading.strip.empty?
      mecab_reading = nodes.map { |n| n[:reading] || extract_kana(n[:text]) }.join
      if mecab_reading != katakana_to_hiragana(preferred_reading)
        nodes = process_kanji_reading(text, preferred_reading)
      end
    end

    # Format nodes into bracket notation
    result = format_nodes(nodes)

    # Restore spaces
    result.gsub(ASCII_SPACE_TOKEN, ' ')
  end

  # MeCab's tokens for each of the texts (one MeCab run for all of them), as
  # lists of [surface, pos1, pos2]: UniDic part of speech, e.g.
  # ["縁", "名詞", "普通名詞"], with empty strings for unknown words.
  def tokens(texts)
    stdout, stderr, status = Open3.capture3(
      *@tokens_cmd,
      stdin_data: texts.map { |text| text.gsub(/[\r\n]/, ' ') + "\n" }.join,
      chdir: MECAB_SUPPORT_DIR
    )
    raise "MeCab failed: #{stderr}" unless status.success?

    stdout.split(/^EOS\n/).map do |block|
      block.each_line(chomp: true).map { |line| line.split("\t", -1).first(3) }
    end
  end

  private

  def build_mecab_command(format_args = MECAB_ARGS)
    mecab_binary = File.join(MECAB_SUPPORT_DIR, 'mecab')

    # Select the right binary for the platform
    if RUBY_PLATFORM.include?('darwin')
      # On macOS, check if we're on ARM (Apple Silicon)
      if `uname -m`.strip == 'arm64'
        mecab_binary += '.arm'
      end
    elsif RUBY_PLATFORM.include?('linux')
      mecab_binary += '.lin'
    elsif RUBY_PLATFORM.include?('win')
      mecab_binary += '.exe'
    end

    # Make sure binary is executable
    File.chmod(0755, mecab_binary) if File.exist?(mecab_binary)

    # Build command with arguments
    cmd = [mecab_binary] + format_args + [
      '-d', UniDic::DIR,
      '-r', File.join(MECAB_SUPPORT_DIR, 'mecabrc')
    ]

    # Set library paths for macOS/Linux
    ENV['DYLD_LIBRARY_PATH'] = MECAB_SUPPORT_DIR
    ENV['LD_LIBRARY_PATH'] = MECAB_SUPPORT_DIR

    cmd
  end

  # Extract the hiragana form of kana text (for comparing MeCab's reading
  # against a preferred reading).
  def extract_kana(text)
    katakana_to_hiragana(text)
  end

  # Build bracket-notation furigana for a word using a known reading.
  # Splits the word into kanji and kana segments, then uses process_kanji_reading
  # to align the reading with the kanji portions.
  def build_furigana_with_reading(word, reading)
    # If the word is all kana, no furigana needed
    return word unless word.match?(/[\u4E00-\u9FFF\u3400-\u4DBF]/)

    # Use the same kanji/reading alignment logic as MeCab output processing
    nodes = process_kanji_reading(word, reading)
    format_nodes(nodes)
  end

  def parse_mecab_output(output, ignore_numbers:)
    nodes = []

    output.split(' ').each do |node|
      break if node.empty?

      # Parse node format: kanji[reading]
      match = node.match(/(.+)\[(.*)\]/)
      next unless match

      kanji = match[1]
      reading = match[2]

      # Skip if kanji equals reading (katakana, punctuation, hiragana, etc.)
      if kanji == reading || reading.empty?
        nodes << { text: kanji, reading: nil }
        next
      end

      # Convert reading from katakana to hiragana
      reading_hiragana = katakana_to_hiragana(reading)

      # Skip if text is already in hiragana
      if kanji == reading_hiragana
        nodes << { text: kanji, reading: nil }
        next
      end

      # Don't add readings for numbers if ignore_numbers is true
      if ignore_numbers && kanji.match?(/[０１２３４５６７８９]/)
        nodes << { text: kanji, reading: nil }
        next
      end

      # Process kanji with readings
      processed_nodes = process_kanji_reading(kanji, reading_hiragana)
      nodes.concat(processed_nodes)
    end

    nodes
  end

  def process_kanji_reading(kanji, reading)
    # Build regex pattern to match kanji against reading
    regex_parts = []
    definitions = []

    i = 0
    while i < kanji.length
      char = kanji[i]

      if kana?(char)
        # Kana characters are inlined in the regex
        hiragana = katakana_to_hiragana(char)
        regex_parts << Regexp.escape(hiragana)
        definitions << { text: char, kanji_chars: nil, group_index: nil }
        i += 1
      else
        # Kanji characters become capture groups
        # Absorb consecutive kanji into one group for regex matching
        kanji_group = ""
        kanji_chars = []
        while i < kanji.length && !kana?(kanji[i])
          kanji_chars << kanji[i]
          kanji_group << kanji[i]
          i += 1
        end

        regex_parts << "(.+?)"  # Lazy match
        definitions << {
          text: kanji_group,
          kanji_chars: kanji_chars,
          group_index: definitions.count { |d| d[:group_index] }
        }
      end
    end

    # Normalize reading to hiragana for regex matching, but keep the original
    # so the stored furigana preserves the stylistic katakana/hiragana choice.
    normalized_reading = katakana_to_hiragana(reading)
    pattern = Regexp.new("^#{regex_parts.join}$")
    match = normalized_reading.match(pattern)

    # If the regex doesn't match (e.g. partial reading that doesn't cover the
    # full word), fall back to the whole word with the full reading.
    unless match
      return [{ text: kanji, reading: reading }]
    end

    # Generate nodes based on the match. Use offsets to slice from the original
    # reading so that katakana/hiragana styling is preserved in the output.
    nodes = []
    definitions.each do |def_info|
      if def_info[:group_index].nil?
        nodes << { text: def_info[:text], reading: nil }
      else
        group_idx = def_info[:group_index] + 1
        offset = match.begin(group_idx)
        length = match[group_idx].length
        group_reading = reading[offset, length]

        # Attempt per-kanji splitting for consecutive kanji groups
        if def_info[:kanji_chars].length > 1
          split = @reading_resolver.resolve(def_info[:kanji_chars], group_reading)
          if split
            split.each { |k, r| nodes << { text: k, reading: r } }
          else
            nodes << { text: def_info[:text], reading: group_reading }
          end
        else
          nodes << { text: def_info[:text], reading: group_reading }
        end
      end
    end

    nodes
  end

  def format_nodes(nodes)
    result = ""

    nodes.each do |node|
      if node[:reading].nil?
        result << node[:text]
      else
        # Add space before bracket notation if not at start and previous char wasn't ]
        add_space = !result.empty? && result[-1] != ']'
        result << ' ' if add_space
        result << "#{node[:text]}[#{node[:reading]}]"
      end
    end

    result
  end

  # Convert katakana to hiragana
  def katakana_to_hiragana(text)
    text.chars.map do |char|
      code = char.ord
      # Katakana range: 0x30A1 - 0x30FF
      # Hiragana range: 0x3041 - 0x309F
      # Skip middle dot (・) and prolonged sound mark (ー)
      if code >= 0x30A1 && code <= 0x30FF && code != 0x30FB && code != 0x30FC
        (code - 0x30A1 + 0x3041).chr('UTF-8')
      else
        char
      end
    end.join
  end

  # Check if character is kana (hiragana or katakana)
  def kana?(char)
    code = char.ord
    (code >= 0x3041 && code <= 0x309F) || # Hiragana
    (code >= 0x30A1 && code <= 0x30FF)    # Katakana
  end

  # Check if MeCab is available
  def self.available?
    File.directory?(MECAB_SUPPORT_DIR) &&
    File.exist?(File.join(MECAB_SUPPORT_DIR, 'mecab'))
  end
end
