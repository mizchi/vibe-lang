#!/usr/bin/env bash
# Parity probe for #402 vibe-check selfhost cutover.
#
# By default (no --strict) compares exit codes only — the phase 1 opt-in
# gate. With --strict, also requires byte-equal stdout, which is the
# phase 2 goal after the selfhost wasi `--human` renderer was unified
# with the host's `Diagnostic::render_with_index`.
#
# Usage:
#   scripts/parity-vibe-check-selfhost.sh [--strict] <file.vibe> [<file.vibe>...]
#
# Env:
#   VIBE_BIN              path to vibe binary (default: debug build)
#   VIBE_MOONRUN_WT_BIN   override moonrun_wt binary
#   VIBE_CHECK_WASI_BUNDLE override check bundle

set -uo pipefail

strict=0
if [ "${1:-}" = "--strict" ]; then
  strict=1
  shift
fi

VIBE_BIN="${VIBE_BIN:-_build/native/debug/build/cmd/vibe/vibe.exe}"

if [ $# -eq 0 ]; then
  echo "usage: $0 [--strict] <file.vibe> [...]" >&2
  exit 2
fi

if [ ! -x "$VIBE_BIN" ]; then
  echo "parity: vibe binary not found at $VIBE_BIN" >&2
  echo "parity: build with 'moon build --target native src/cmd/vibe'" >&2
  exit 2
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail=0
total=0
equal=0
exit_match=0
for file in "$@"; do
  total=$((total+1))
  "$VIBE_BIN" check "$file" > "$tmpdir/native.out" 2>&1
  native_exit=$?
  VIBE_CHECK_SELFHOST=1 "$VIBE_BIN" check "$file" > "$tmpdir/selfhost.out" 2>&1
  selfhost_exit=$?

  if [ "$native_exit" = "$selfhost_exit" ]; then
    exit_match=$((exit_match+1))
    if diff -q "$tmpdir/native.out" "$tmpdir/selfhost.out" >/dev/null; then
      equal=$((equal+1))
      printf 'byte-equal  %s  (exit=%d)\n' "$file" "$native_exit"
    elif [ $strict -eq 1 ]; then
      printf 'DIVERGE     %s  exit=%d but stdout differs\n' "$file" "$native_exit"
      diff -u "$tmpdir/native.out" "$tmpdir/selfhost.out" | head -20
      fail=1
    else
      printf 'exit-match  %s  (exit=%d, stdout differs)\n' "$file" "$native_exit"
    fi
  else
    printf 'DIVERGE     %s  native=%d selfhost=%d\n' "$file" "$native_exit" "$selfhost_exit"
    fail=1
  fi
done

echo ""
echo "summary: total=$total exit-match=$exit_match byte-equal=$equal"

exit "$fail"
