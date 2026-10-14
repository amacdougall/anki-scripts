require 'open3'
require 'shellwords'
require 'tmpdir'
require 'fileutils'

module GeminiTTS
  # Audio helpers for Gemini's native output: raw 16-bit signed little-endian
  # PCM, mono, 24 kHz. WAV wrapping is pure Ruby; MP3 encoding and the
  # truncation analysis shell out to sox.
  module Audio
    SAMPLE_RATE = 24_000
    BITS = 16
    CHANNELS = 1
    BYTES_PER_SECOND = SAMPLE_RATE * CHANNELS * BITS / 8

    # Truncation guard. A complete utterance ends with a finishing pause, so it
    # has BOTH ample trailing silence AND a quiet tail; a clip cut mid-word fails
    # at least one. We flag if EITHER holds (calibrated on real clips: complete ≈
    # 0.30–0.66s trailing / ≤0.003 tail RMS; truncated ≈ ≤0.12s trailing / ≥0.02
    # tail RMS — a clean ~10× gap on both axes). OR rather than AND because MP3
    # encoder padding can pad the tail past the trailing-silence threshold even on
    # a hard cut, where only the tail-RMS half catches it. It inspects how the
    # clip ends, so it's independent of the input→output length relationship.
    MIN_TRAILING_SILENCE = 0.10 # seconds
    MAX_TAIL_RMS = 0.01         # RMS amplitude of the final 0.25s

    module_function

    def duration(pcm)
      pcm.bytesize.to_f / BYTES_PER_SECOND
    end

    # PCM wrapped in a 44-byte RIFF/WAVE header.
    def wav(pcm)
      byte_rate = BYTES_PER_SECOND
      block_align = CHANNELS * BITS / 8
      header = ['RIFF', 36 + pcm.bytesize, 'WAVE', 'fmt ', 16, 1, CHANNELS, SAMPLE_RATE,
                byte_rate, block_align, BITS, 'data', pcm.bytesize]
               .pack('a4Va4a4VvvVVvva4V')
      header + pcm.b
    end

    def mp3(pcm)
      out, err, status = Open3.capture3(*sox_raw_input, '-t', 'mp3', '-',
                                        binmode: true, stdin_data: pcm)
      raise Error, "sox failed to encode PCM to MP3: #{err.to_s[0, 300]}" unless status.success? && !out.empty?

      out
    end

    # True if the PCM ends abruptly (likely truncated mid-utterance). Analyzed on
    # the raw audio, which has no MP3 encoder padding to skew trailing silence.
    def abrupt_end_pcm?(pcm)
      return false if pcm.nil? || pcm.empty?

      with_tmp('.wav') do |path|
        File.binwrite(path, wav(pcm))
        abrupt_end?(path)
      end
    end

    # True if the audio file at `path` ends abruptly: almost no trailing silence
    # OR high energy in the final quarter second.
    def abrupt_end?(path)
      full = file_duration(path)
      return false unless full && full > 0.3

      with_tmp('.wav') do |trimmed|
        with_tmp('.wav') do |tail|
          # trailing silence = full duration minus the duration once trailing quiet is removed
          system('sox', path, trimmed, 'reverse', 'silence', '1', '0.05', '0.3%', 'reverse',
                 out: File::NULL, err: File::NULL)
          trailing = full - (file_duration(trimmed) || full)
          # energy over the final 0.25s
          system('sox', path, tail, 'trim', '-0.25', out: File::NULL, err: File::NULL)
          rms = file_rms(tail) || 0.0
          trailing < MIN_TRAILING_SILENCE || rms > MAX_TAIL_RMS
        end
      end
    end

    def file_duration(path)
      out = `soxi -D #{Shellwords.escape(path)} 2>/dev/null`.strip
      out.empty? ? nil : out.to_f
    end

    def file_rms(path)
      out = `sox #{Shellwords.escape(path)} -n stat 2>&1`
      out =~ /RMS\s+amplitude:\s*([\d.]+)/ ? Regexp.last_match(1).to_f : nil
    end

    def sox_raw_input
      ['sox', '-t', 'raw', '-r', SAMPLE_RATE.to_s, '-e', 'signed', '-b', BITS.to_s,
       '-c', CHANNELS.to_s, '-']
    end

    def with_tmp(ext)
      path = File.join(Dir.tmpdir, "gemini_tts_#{Process.pid}_#{rand(1 << 32)}#{ext}")
      yield path
    ensure
      FileUtils.rm_f(path)
    end
  end
end
