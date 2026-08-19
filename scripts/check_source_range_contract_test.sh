#!/usr/bin/env bash
# Self-test for scripts/check_source_range_contract.sh.
#
# The gate's whole value depends on its fixture separating byte from codepoint
# columns; on an ASCII fixture every assertion in it is trivially true. These
# cases pin that, plus the two ways a checker like this usually fails open:
# falling back to a different compiler than the caller named, and reporting ok
# when the compiler could not run at all.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
CHECK="$ROOT_DIR/scripts/check_source_range_contract.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ranges_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "source-range self-test: FAIL: $1" >&2; exit 1; }

# 1. A named compiler that does not exist is an error, not a silent fallback to
#    whatever generation happens to be newest -- otherwise the caller is told
#    about a compiler they did not run.
set +e; out="$(RANGE_STAGE2="$TMP/nope.wasm" bash "$CHECK" 2>&1)"; rc=$?; set -e
[ "$rc" != "0" ] || fail "a missing explicit compiler passed"
grep -qF "RANGE_STAGE2 does not exist" <<<"$out" || fail "a missing explicit compiler did not say so"
echo "source-range self-test: ok: a missing explicit compiler is an error"

# 2. A compiler that cannot run must fail, not report ok. Every surface answers
#    empty, and empty is the CLI's spelling of "clean" -- exactly the shape
#    this whole gate exists to keep from passing.
: > "$TMP/empty.wasm"
set +e; out="$(RANGE_STAGE2="$TMP/empty.wasm" bash "$CHECK" 2>&1)"; rc=$?; set -e
[ "$rc" != "0" ] || fail "an unusable compiler reported ok"
echo "source-range self-test: ok: an unusable compiler fails"

# 3. The fixture must separate byte from codepoint columns. Strip the emoji and
#    the gate has to refuse rather than pass vacuously -- proven by editing the
#    check's own fixture line in a copy.
sed 's/\\xf0\\x9f\\x8e\\x89/x/g' "$CHECK" > "$TMP/ascii_check.sh"
set +e; out="$(bash "$TMP/ascii_check.sh" 2>&1)"; rc=$?; set -e
[ "$rc" != "0" ] || fail "an ASCII-only fixture passed; every assertion would be vacuous"
grep -qF "does not separate byte from codepoint" <<<"$out" || fail "an ASCII-only fixture failed for the wrong reason: $out"
echo "source-range self-test: ok: an ASCII-only fixture is refused as vacuous"

# 4. The real run reports all three column numbers, and they must be distinct.
#    A summary line that quietly printed the same number three times would mean
#    the fixture stopped doing its job.
set +e; out="$(bash "$CHECK" 2>&1)"; rc=$?; set -e
[ "$rc" = "0" ] || fail "the real check did not pass: $out"
summary="$(grep -o 'byte col [0-9]*, codepoint col [0-9]*, UTF-16 col [0-9]*' <<<"$out")"
[ -n "$summary" ] || fail "the check printed no column summary"
read -r b c u <<<"$(grep -o '[0-9]\+' <<<"$summary" | tr '\n' ' ')"
[ "$b" != "$c" ] && [ "$b" != "$u" ] && [ "$c" != "$u" ] || fail "the three columns are not distinct: $summary"
echo "source-range self-test: ok: the run reports three distinct columns ($summary)"

echo "source-range self-test: all cases passed"
