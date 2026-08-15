#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$ROOT_DIR/_build/vibe_fmt_parse_guard_test.$$"
probe="$work/probe.vibe"
original="$work/original.vibe"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"

# Codex review on #1822: the set of tokens that may precede a capitalized
# condition tail is unbounded. Unary `!` is intentionally not one of the known
# governors, so the token-only formatter guesses that `Flag` is a struct
# literal and emits `Flag::{`. The public formatter must parse its candidate
# output and refuse the write instead of silently replacing valid source with
# invalid source.
cat >"$probe" <<'VIBE'
fn f() -> Int {
  if !Flag {
    1
  } else {
    0
  }
}
VIBE
cp "$probe" "$original"

if bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$probe" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter accepted its invalid Flag::{ output" >&2
  sed -n '1,20p' "$probe" >&2
  exit 1
fi
if ! cmp -s "$probe" "$original"; then
  echo "vibe_fmt_parse_guard_test: formatter modified the input after declining it" >&2
  exit 1
fi

echo "vibe_fmt_parse_guard_test: ok"
