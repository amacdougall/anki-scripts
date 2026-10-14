class PitchAccentRenderer
  # Small kana that combine with previous character to form a single mora
  COMBINERS = ['ゃ', 'ゅ', 'ょ', 'ャ', 'ュ', 'ョ', 'ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ',
               'ァ', 'ィ', 'ゥ', 'ェ', 'ォ', 'ゎ', 'ヮ', 'ゕ', 'ゖ', 'ヵ', 'ヶ']

  # Legacy HTML comment marker for generated pitch accent. No longer written —
  # the generated::pitch-accent tag is now the "generated" signal — but kept so
  # generate-pitch-accent.rb can still recognize pre-migration notes (fallback).
  GENERATED_MARKER = '<!-- pitch-accent-generated -->'

  # Convert pitch pattern to Kaishi HTML
  # Args: reading (katakana/hiragana), pitch_pattern (e.g., "LlHHHHH")
  # Returns: HTML string (no marker comment; provenance lives in an Anki tag)
  #
  # Note: Pattern is character-based (not mora-based):
  #   - Uppercase letters (L/H) represent pitch for regular kana
  #   - Lowercase letters (l/h) represent pitch for small kana (ゃゅょ etc.)
  #   - Pattern may include an extra character for particle pitch
  def self.to_kaishi_html(reading, pitch_pattern)
    return nil if reading.nil? || pitch_pattern.nil?

    # Convert to hiragana for consistency
    reading_hira = to_hiragana(reading)

    # Split into characters and morae
    chars = reading_hira.chars
    morae = split_into_morae(reading_hira)

    # Map pitch pattern to individual characters
    # Pattern is character-based: uppercase for regular kana, lowercase for small kana
    # Pattern length should be chars.length or chars.length + 1 (includes particle)
    pattern_chars = pitch_pattern.chars

    # Build mora pitch mapping by examining constituent characters
    mora_pitches = []
    char_idx = 0

    morae.each do |mora|
      # Get pitch letters for all characters in this mora
      mora_char_count = mora.chars.length
      pitch_letters = pattern_chars[char_idx, mora_char_count] || []

      # Find the uppercase letter (regular kana determines mora pitch)
      # Lowercase letters are for small kana within the mora
      uppercase_pitch = pitch_letters.find { |p| p == p.upcase } || pitch_letters.first

      # Default to 'L' if no pattern available
      mora_pitches << (uppercase_pitch&.upcase || 'L')

      char_idx += mora_char_count
    end

    # Build HTML based on mora pitches
    html_parts = []
    i = 0

    while i < morae.length
      mora = morae[i]
      pitch = mora_pitches[i]

      if pitch == 'H'
        # Check if this is a drop point (H followed by L)
        has_drop = (i + 1 < morae.length && mora_pitches[i + 1] == 'L')

        # Collect consecutive high morae
        high_section = [mora]
        j = i + 1

        while j < morae.length && mora_pitches[j] == 'H'
          high_section << morae[j]
          j += 1
        end

        # Check if last mora in high section has a drop after it
        has_drop = (j < morae.length && mora_pitches[j] == 'L')

        # Generate span for the entire high section
        high_text = high_section.join('')
        html_parts << span_with_overline(high_text, has_drop)

        i = j
      else
        # Low pitch - plain text
        html_parts << mora
        i += 1
      end
    end

    html_parts.join('')
  end

  private

  # Generate HTML for high-pitched section with optional drop marker
  def self.span_with_overline(text, has_drop)
    if has_drop
      # High with drop (overline + vertical line)
      <<~HTML.strip
        <span style="display:inline-block;position:relative;padding-right:0.1em;margin-right:0.1em;"><span style="display:inline;">#{text}</span><span style="border-color:currentColor;display:block;user-select:none;pointer-events:none;position:absolute;top:0.1em;left:0;right:0;height:0;border-top-width:0.1em;border-top-style:solid;right:-0.1em;height:0.4em;border-right-width:0.1em;border-right-style:solid;"></span></span>
      HTML
    else
      # High without drop (overline only)
      <<~HTML.strip
        <span style="display:inline-block;position:relative;"><span style="display:inline;">#{text}</span><span style="border-color:currentColor;display:block;user-select:none;pointer-events:none;position:absolute;top:0.1em;left:0;right:0;height:0;border-top-width:0.1em;border-top-style:solid;"></span></span>
      HTML
    end
  end

  # Split text into morae (handles small kana)
  def self.split_into_morae(text)
    morae = []
    chars = text.chars
    i = 0

    while i < chars.length
      char = chars[i]

      # Check if next character is a combiner
      if i + 1 < chars.length && COMBINERS.include?(chars[i + 1])
        morae << char + chars[i + 1]
        i += 2
      else
        morae << char
        i += 1
      end
    end

    morae
  end

  # Convert katakana to hiragana
  def self.to_hiragana(text)
    text.tr('ァ-ン', 'ぁ-ん')
  end
end
