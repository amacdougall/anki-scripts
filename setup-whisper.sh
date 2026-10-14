#!/usr/bin/env bash
# Sets up local Whisper (whisper.cpp) for the audio reading check in
# generate-gemini-audio.rb, which transcribes each generated clip and retries
# words the voice misread. Optional: without Whisper, that check is skipped.
#
#   1. whisper-cli: uses one already on PATH; otherwise installs Homebrew's
#      whisper-cpp on macOS, or builds whisper.cpp from source into
#      data/whisper/whisper.cpp (needs git, cmake and a C++ compiler).
#   2. The large-v3-turbo model (~1.6 GB) into data/whisper/, checksum-verified.
#      Skip the download by pointing WHISPER_MODEL at a copy you already have.
#
# Re-running is safe; finished steps are skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WHISPER_DIR="$ROOT/data/whisper"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
MODEL_SHA256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
MODEL="$WHISPER_DIR/ggml-large-v3-turbo.bin"

mkdir -p "$WHISPER_DIR"

sha256() {
  if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1
  fi
}

# --- whisper-cli -----------------------------------------------------------

if [[ -n "${WHISPER_CLI:-}" ]]; then
  echo "Using whisper-cli from WHISPER_CLI: $WHISPER_CLI"
elif [[ -x "$WHISPER_DIR/whisper.cpp/build/bin/whisper-cli" ]]; then
  echo "whisper-cli already built in data/whisper/whisper.cpp"
elif command -v whisper-cli >/dev/null; then
  echo "Using whisper-cli on PATH: $(command -v whisper-cli)"
elif [[ "$(uname)" == "Darwin" ]] && command -v brew >/dev/null; then
  echo "Installing whisper-cpp with Homebrew..."
  brew install whisper-cpp
else
  for tool in git cmake; do
    command -v "$tool" >/dev/null || { echo "Building whisper.cpp needs $tool; install it and re-run." >&2; exit 1; }
  done
  echo "Building whisper.cpp from source (a few minutes)..."
  [[ -d "$WHISPER_DIR/whisper.cpp" ]] ||
    git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR/whisper.cpp"
  cmake -S "$WHISPER_DIR/whisper.cpp" -B "$WHISPER_DIR/whisper.cpp/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$WHISPER_DIR/whisper.cpp/build" --config Release -j --target whisper-cli
fi

# --- model -----------------------------------------------------------------

if [[ -n "${WHISPER_MODEL:-}" ]]; then
  echo "Using model from WHISPER_MODEL: $WHISPER_MODEL"
elif [[ -f "$MODEL" ]]; then
  echo "Model already downloaded: data/whisper/$(basename "$MODEL")"
else
  echo "Downloading Whisper large-v3-turbo (~1.6 GB)..."
  curl -fL --progress-bar -C - -o "$MODEL.part" "$MODEL_URL"
  actual="$(sha256 "$MODEL.part")"
  if [[ "$actual" != "$MODEL_SHA256" ]]; then
    echo "Checksum mismatch for the model (got $actual); deleting the download." >&2
    rm -f "$MODEL.part"
    exit 1
  fi
  mv "$MODEL.part" "$MODEL"
fi

# --- check -----------------------------------------------------------------

if "$ROOT/bin/transcribe" --check; then
  echo "Whisper is ready; generate-gemini-audio.rb will run the reading check."
else
  echo "Setup finished, but bin/transcribe still can't find whisper-cli or the model." >&2
  exit 1
fi
