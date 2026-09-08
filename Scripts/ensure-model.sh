#!/usr/bin/env bash
# Ensures the default Whisper model (ggml-tiny.en.bin) is present, downloading it
# if it is missing. The public repo gitignores vx-ui/Resources/Models/, so a fresh
# checkout has no model at all — this script is the single place that knows where
# the model lives and where to fetch it from.
#
# Idempotent: a second run is a no-op. Prints the model path on stdout (progress
# and errors go to stderr) so callers can capture it:
#
#   MODEL="$(Scripts/ensure-model.sh)"
#
# Used by Scripts/package-app.sh (app bundling) and by the vx-rs contract tests
# (run it before `VX_REQUIRE_MODEL=1 cargo test`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT/vx-ui/Resources/Models"
MODEL_PATH="$MODEL_DIR/ggml-tiny.en.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "[vx] No model at $MODEL_PATH; downloading ggml-tiny.en.bin…" >&2
  mkdir -p "$MODEL_DIR"
  curl -fL --retry 3 -o "$MODEL_PATH" "$URL" \
    || { echo "[vx] ❌ Failed to download the default model" >&2; rm -f "$MODEL_PATH"; exit 1; }
fi

echo "$MODEL_PATH"
