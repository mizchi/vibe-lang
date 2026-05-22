#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "selfhost-portable-boundary: $*" >&2
  exit 1
}

require_line() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "$pattern" "$ROOT_DIR/$file"; then
    fail "missing expected pure boundary: $label ($file)"
  fi
}

forbid_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -En "$pattern" "$ROOT_DIR/$file" >/tmp/vibe_portable_boundary_hits.$$; then
    cat /tmp/vibe_portable_boundary_hits.$$ >&2
    rm -f /tmp/vibe_portable_boundary_hits.$$
    fail "native capability leaked into portable boundary: $label ($file)"
  fi
  rm -f /tmp/vibe_portable_boundary_hits.$$
}

native_effect_pattern='with \{[^}]*(Fs|Process|Socket|Net)|perform (Fs|Process|Socket|Http)::|compile_file_fs|session-http|daemon'

require_line \
  "vibe/compiler/entry/source_compile/index.vibe" \
  '^export let compile_source: \(String\) -> Bytes with \{ Error \}' \
  "compile_source stays in-memory"
require_line \
  "vibe/compiler/entry/source_compile/index.vibe" \
  '^export let compile_source_wasi: \(String, String\) -> Bytes with \{ Error \}' \
  "compile_source_wasi stays in-memory"
require_line \
  "vibe/compiler/entry/source_compile/index.vibe" \
  '^export let compile_source_wasi_mode: \(String, String, String\) -> Bytes with \{ Error \}' \
  "compile_source_wasi_mode stays in-memory"
require_line \
  "vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  '^export let compile_source_wasi_only: \(String, String\) -> Bytes with \{ Error \}' \
  "compile_source_wasi_only stays in-memory"
require_line \
  "vibe/compiler/entry/compiler/fs_compile/index.vibe" \
  '^export let compile_with_closure_sources_wasi_mode_uncached: \(String, String, Array\[\(String, String\)\], String, String\) -> Bytes with \{ Error \}' \
  "direct component closure compile stays in-memory"

forbid_pattern \
  "vibe/compiler/selfhost_cli_direct_component_entry.vibe" \
  "$native_effect_pattern" \
  "direct component entry"
forbid_pattern \
  "vibe/compiler/entry/source_compile/index.vibe" \
  "$native_effect_pattern" \
  "source compile API"
forbid_pattern \
  "vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "$native_effect_pattern" \
  "wasi source compile API"

echo "selfhost portable boundary: ok"
