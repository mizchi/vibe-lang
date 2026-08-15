#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$ROOT_DIR/_build/vibe_fmt_parse_guard_test.$$"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"

# This test used to assert the opposite of what it asserts now, and the change
# is the point.
#
# It was written for #1822, when the formatter still rewrote `Point { x: 1 }`
# into `Point::{ x: 1 }` and needed a hand-written exclusion for every token
# that could sit before the brace. `!` was not one of them, so `if !Flag {`
# became `if !Flag::{` -- and the test asserted that the entry's parse guard
# CAUGHT that, by requiring vibe_fmt.sh to fail on this input.
#
# #1821 then measured what the rewrite was for: across 948 files under lib and
# 727 candidates under fixtures/ and scripts/, it fired exactly once, on a
# fixture that does not compile. Its whole useful domain was source the parser
# rejects; on source it accepts it could only misfire, which it did six times
# (#945, #1429, #1505, `!=`, `in`, `!`). It is gone.
#
# So this input no longer corrupts, and demanding a refusal would demand the bug
# back. What is worth pinning is the outcome -- the shape formats, and it
# formats to itself.

pass_input="$work/pass.vibe"
cat >"$pass_input" <<'VIBE'
fn f() -> Int {
  if !Flag {
    1
  } else {
    0
  }
}
VIBE
cp "$pass_input" "$work/pass.original"

if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$pass_input" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter declined a file it should format" >&2
  exit 1
fi
if grep -q '::{' "$pass_input"; then
  echo "vibe_fmt_parse_guard_test: formatter inserted a struct-literal :: (#1821 regression)" >&2
  sed -n '1,20p' "$pass_input" >&2
  exit 1
fi
if ! cmp -s "$pass_input" "$work/pass.original"; then
  echo "vibe_fmt_parse_guard_test: formatter changed a file that was already formatted" >&2
  diff "$work/pass.original" "$pass_input" >&2 || true
  exit 1
fi

# The guard's other half, which IS still reachable: it must not over-refuse.
# It rejects a rewrite that BREAKS a file, not any file that happens not to
# parse -- the promise is "no worse", not "only valid input". Getting this
# backwards would make the formatter useless on exactly the broken files a
# person most wants to run it on.
broken="$work/broken.vibe"
printf 'fn f( {\n  1\n' >"$broken"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" "$broken" >/dev/null 2>&1; then
  echo "vibe_fmt_parse_guard_test: formatter refused a file that never parsed;" >&2
  echo "  the guard rejects rewrites that BREAK a file, not files already broken" >&2
  exit 1
fi

echo "vibe_fmt_parse_guard_test: ok"
