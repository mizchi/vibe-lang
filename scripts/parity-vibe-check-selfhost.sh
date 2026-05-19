#!/usr/bin/env bash
# Phase 1 #402 parity probe: compare `vibe check` exit codes for the
# native path and the opt-in selfhost-wasi path. Output formats are NOT
# expected to match byte-for-byte (selfhost --human is terser than the
# host renderer); the gate is `exit_native == exit_selfhost`.
#
# Usage:
#   scripts/parity-vibe-check-selfhost.sh <file.vibe> [<file.vibe>...]
#
# Env:
#   VIBE_BIN              path to vibe binary (default: debug build)
#   VIBE_MOONRUN_WT_BIN   override moonrun_wt binary
#   VIBE_CHECK_WASI_BUNDLE override check bundle

set -uo pipefail

VIBE_BIN="${VIBE_BIN:-_build/native/debug/build/cmd/vibe/vibe.exe}"

if [ $# -eq 0 ]; then
  echo "usage: $0 <file.vibe> [...]" >&2
  exit 2
fi

if [ ! -x "$VIBE_BIN" ]; then
  echo "parity: vibe binary not found at $VIBE_BIN" >&2
  echo "parity: build with 'moon build --target native src/cmd/vibe'" >&2
  exit 2
fi

fail=0
for file in "$@"; do
  "$VIBE_BIN" check "$file" >/dev/null 2>&1
  native_exit=$?
  VIBE_CHECK_SELFHOST=1 "$VIBE_BIN" check "$file" >/dev/null 2>&1
  selfhost_exit=$?
  if [ "$native_exit" = "$selfhost_exit" ]; then
    printf 'ok       %s  (exit=%d)\n' "$file" "$native_exit"
  else
    printf 'DIVERGE  %s  native=%d selfhost=%d\n' "$file" "$native_exit" "$selfhost_exit"
    fail=1
  fi
done

exit "$fail"
