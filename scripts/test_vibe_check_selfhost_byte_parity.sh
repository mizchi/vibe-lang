#!/usr/bin/env bash
# Phase 4 byte-equal parity gate for #402.
#
# Verifies that the selfhost `vibe check` (via VIBE_CHECK_SELFHOST=1) emits
# byte-identical stdout/stderr to the native checker on the examples/ corpus.
# This is the strict variant of scripts/parity-vibe-check-selfhost.sh: any
# diff fails the gate, not just exit code mismatches.
#
# Env overrides:
#   VIBE_CHECK_SELFHOST_BYTE_PARITY_FILES  whitespace-separated file list
#                                          (default: examples/*.vibe)
#   VIBE_BIN                               native vibe binary
#   VIBE_CHECK_WASI_BUNDLE                 .cwasm bundle path
#   VIBE_MOONRUN_WT_BIN                    moonrun_wt binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
WASI_RAW="$PROJECT_ROOT/_build/wasm/release/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
WASI_OPT="$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.wasm"
WASI_CWASM="${VIBE_CHECK_WASI_BUNDLE:-$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.cwasm}"
MOONRUN_WT="${VIBE_MOONRUN_WT_BIN:-$PROJECT_ROOT/tools/moonrun_wasmtime/target/release/moonrun_wt}"

if [ ! -x "$VIBE_BIN" ]; then
  echo "[byte-parity] building native vibe binary..." >&2
  moon build --target native src/cmd/vibe --warn-list '-29'
fi

# Ensure the opt .wasm exists and is newer than the source tree; rebuild via
# the canonical script if missing.
if [ ! -f "$WASI_OPT" ] ||
  find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$WASI_OPT" -print -quit 2>/dev/null | grep -q . ||
  find "$PROJECT_ROOT" -maxdepth 1 -type f \( -name 'moon.mod' -o -name 'moon.mod.json' \) -newer "$WASI_OPT" -print -quit 2>/dev/null | grep -q .; then
  echo "[byte-parity] rebuilding selfhost wasi bundle..." >&2
  bash "$SCRIPT_DIR/build_selfhost_wasi_opt.sh"
fi

if [ ! -x "$MOONRUN_WT" ]; then
  echo "[byte-parity] building moonrun_wt..." >&2
  cargo build --release --manifest-path "$PROJECT_ROOT/tools/moonrun_wasmtime/Cargo.toml" >&2
fi
if [ ! -x "$MOONRUN_WT" ]; then
  echo "[byte-parity] moonrun_wt build did not produce $MOONRUN_WT" >&2
  exit 2
fi

# AOT precompile when the .cwasm is stale.
if [ ! -f "$WASI_CWASM" ] || [ "$WASI_OPT" -nt "$WASI_CWASM" ]; then
  echo "[byte-parity] AOT-compiling $(basename "$WASI_OPT") → $(basename "$WASI_CWASM")..." >&2
  "$MOONRUN_WT" --precompile "$WASI_OPT" -o "$WASI_CWASM"
fi

if [ -n "${VIBE_CHECK_SELFHOST_BYTE_PARITY_FILES:-}" ]; then
  # shellcheck disable=SC2206
  files=( ${VIBE_CHECK_SELFHOST_BYTE_PARITY_FILES} )
else
  files=( "$PROJECT_ROOT"/examples/*.vibe )
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "[byte-parity] no input files resolved" >&2
  exit 2
fi

echo "[byte-parity] files=${#files[@]} bundle=$WASI_CWASM"

# Disable check_debug so optional `[check_debug]` log lines from the host
# CLI never sneak into the diff under CI envs that opt into debug logging.
VIBE_CHECK_DEBUG=0 \
VIBE_BIN="$VIBE_BIN" \
VIBE_CHECK_WASI_BUNDLE="$WASI_CWASM" \
VIBE_MOONRUN_WT_BIN="$MOONRUN_WT" \
bash "$SCRIPT_DIR/parity-vibe-check-selfhost.sh" --strict "${files[@]}"
