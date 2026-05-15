#!/usr/bin/env bash
# Broad compiled-package sweep — extracted from justfile `test-vibe-package-suite`.
set -euo pipefail

ulimit_n="${VIBE_TEST_ULIMIT_N:-8192}"
jobs="${VIBE_TEST_JOBS:-1}"

source scripts/ensure_native_cli.sh
ulimit -n "$ulimit_n"
_build/native/debug/build/cmd/vibe/vibe.exe test \
  --unstable-async \
  --jobs "$jobs" \
  examples \
  vibe/prelude \
  vibe/path \
  vibe/io \
  vibe/fs \
  vibe/time \
  vibe/random \
  vibe/process \
  vibe/shell \
  vibe/x/rlm \
  vibe/socket/socket_test.vibe \
  vibe/http/http_test.vibe \
  vibe/http/high_level_test.vibe \
  vibe/collection \
  vibe/json \
  vibe/sha1 \
  vibe/x \
  vibe/x/args \
  vibe/x/jsonschema \
  vibe/wasm/wasm_parser \
  vibe/wasm/wat_parser \
  vibe/wasm/component_parser \
  vibe/wasm/wat_encoder
