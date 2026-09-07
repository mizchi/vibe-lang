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

# A doc comment naming a native entry point is a REFERENCE, not a leak: the
# whole point of these files is to explain how they differ from the FS lane, so
# `-- see compile_file_fs_mode's comment` is exactly the prose we want. The scan
# strips `///` and `//` comment lines before matching. Code is what leaks
# capability; prose about code does not.
#
# It strips whole comment LINES only, not trailing comments after code -- a
# stripped tail would let `let x = 1 // perform Fs::read_file` hide a real call
# on the same line if the two were ever reordered. A comment line is the one
# shape that cannot execute.
forbid_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -vE '^[[:space:]]*(///?|//#)' "$ROOT_DIR/$file" \
    | grep -En "$pattern" >/tmp/vibe_portable_boundary_hits.$$; then
    cat /tmp/vibe_portable_boundary_hits.$$ >&2
    rm -f /tmp/vibe_portable_boundary_hits.$$
    fail "native capability leaked into portable boundary: $label ($file)"
  fi
  rm -f /tmp/vibe_portable_boundary_hits.$$
}

native_effect_pattern='with \{[^}]*(Fs|Process|Socket|Net)|perform (Fs|Process|Socket|Http)::|compile_file_fs|session-http|daemon'

# The boundary is declared in the package CONTRACT (`index.vpkg`, ADR-0070),
# not in an `index.vibe` facade -- and its effect row is spelled `with
# Exception`, not `with { Error }` (ADR-0085). This gate asserted the older
# form at the older path for long enough that both had gone: it reported
# "missing expected pure boundary" for files that no longer exist, while every
# boundary it names was intact in the contract beside them. Nothing caught it
# because the gate runs in no CI job (#2577).
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source\(source: String\) -> Bytes with Exception$' \
  "compile_source stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source_wasi\(source: String, entry_name: String\) -> Bytes with Exception$' \
  "compile_source_wasi stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source_wasi_mode\(source: String, entry_name: String, mode: String\) -> Bytes with Exception$' \
  "compile_source_wasi_mode stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  '^export fn compile_source_wasi_only\(source: String, entry_name: String\) -> Bytes with Exception' \
  "compile_source_wasi_only stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/compiler/fs_compile/index.vpkg" \
  '^fn compile_with_closure_sources_wasi_mode_uncached\(main_source: String, main_path: String, sources: Array\[\(String, String\)\], entry_name: String, mode: String\) -> Bytes with Exception$' \
  "direct component closure compile stays in-memory"

forbid_pattern \
  "lib/@vibe/compiler/cli_direct_component_entry.vibe" \
  "$native_effect_pattern" \
  "direct component entry"
forbid_pattern \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "$native_effect_pattern" \
  "source compile API"
forbid_pattern \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "$native_effect_pattern" \
  "wasi source compile API"

echo "selfhost portable boundary: ok"
