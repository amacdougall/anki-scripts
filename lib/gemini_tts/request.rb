module GeminiTTS
  # Builds generateContent request bodies. The two model generations take
  # delivery direction in different places:
  #
  # - 3.1 and earlier: `style` is prose prepended to the text, separated by a
  #   TRANSCRIPT marker. `[bracketed]` text is read as an audio tag.
  # - 3.8+: the text is a verbatim transcript (a prefix would be spoken), so
  #   `style` goes in each part's `speechMetadata.style`, and `[cue]`s in the
  #   text split it into separately styled parts. `<angle>` vocal events
  #   (`<giggle>`, `<sigh>`, `<short pause>`) pass through inline.
  module Request
    module_function

    def build(text, voice:, model:, style: nil)
      if GeminiTTS.transcript_model?(model)
        transcript(text, voice: voice, style: style)
      else
        legacy(text, voice: voice, style: style)
      end
    end

    def legacy(text, voice:, style: nil)
      s = style.to_s.strip
      input = s.empty? ? text : "#{s}\n\n#### TRANSCRIPT\n\n#{text}"
      {
        contents: [{ parts: [{ text: input }] }],
        generationConfig: {
          responseModalities: ['AUDIO'],
          speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } }
        }
      }
    end

    # `voice` (unlike prebuiltVoiceConfig) also accepts designed `voice_...` IDs
    # and `voicekey_...` replication keys. Raw L16 is requested explicitly because
    # 3.8 defaults to WAV.
    def transcript(text, voice:, style: nil)
      {
        contents: [{ parts: transcript_parts(text, style) }],
        generationConfig: {
          responseModalities: ['AUDIO'],
          speechConfig: { voiceConfig: { voice: voice } },
          responseFormat: { audio: { mimeType: 'AUDIO_L16', sampleRate: Audio::SAMPLE_RATE } }
        }
      }
    end

    # Split the transcript at `[bracketed]` delivery cues so each cue becomes a
    # sustained style for the text that follows it (until the next cue), e.g.
    # `Fine. [sneering] Almost as beautiful as me.` => two parts, the second
    # styled "<base>; sneering". Text before the first cue carries the base style
    # alone.
    def transcript_parts(text, base_style)
      base = base_style.to_s.strip
      parts = []
      style = base
      text.to_s.split(/(\[[^\]]*\])/).each do |piece|
        if piece =~ /\A\[([^\]]*)\]\z/
          cue = Regexp.last_match(1).strip
          style = [base, cue].reject(&:empty?).join('; ')
        elsif !piece.strip.empty?
          part = { text: piece.strip }
          part[:speechMetadata] = { style: style } unless style.empty?
          parts << part
        end
      end
      parts.empty? ? [{ text: text.to_s }] : parts
    end
  end
end
