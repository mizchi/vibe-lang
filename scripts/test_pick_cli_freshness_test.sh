#!/usr/bin/env bash
# Self-test for scripts/test_pick_cli_freshness.sh (#2248 rule: a gate is
# trusted only once it has been shown to fail).
#
# Each case copies runtime/vibe, removes ONE of the two freshness comparisons
# from pick_cli, checks that the edit landed (an edit that matched nothing
# would pass while proving nothing), and asserts the gate goes red. The last
# case runs the gate on the unmodified launcher and asserts green.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/test_pick_cli_freshness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-pick-cli-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "pick-cli-freshness self-test FAIL: $*" >&2; exit 1; }
unset VIBE_PICK_CLI_LAUNCHER

# mutate NAME PATTERN REPLACEMENT: write $WORK/NAME, runtime/vibe with the
# first line matching PATTERN (a sed BRE) rewritten, and prove the edit landed.
mutate() {
  local name="$1" pattern="$2" replacement="$3"
  local out="$WORK/$name"
  cp "$ROOT/runtime/vibe" "$out"
  sed "s|$pattern|$replacement|" "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  cmp -s "$ROOT/runtime/vibe" "$out" && fail "[$name] the mutation matched nothing in runtime/vibe"
  return 0
}
# expect_red NAME: the gate must fail on $WORK/NAME. The launcher path is
# checked first -- an empty or missing override would make the gate fall back
# to the real runtime/vibe and pass while proving nothing.
expect_red() {
  local name="$1" launcher="$WORK/$1"
  [ -s "$launcher" ] || fail "[$name] mutated launcher missing: $launcher"
  if VIBE_PICK_CLI_LAUNCHER="$launcher" bash "$GATE" >"$WORK/$name.log" 2>&1; then
    cat "$WORK/$name.log" >&2
    fail "[$name] the gate PASSED on a launcher without that freshness check"
  fi
  echo "pick-cli-freshness self-test [$name]: red as expected"
}

# The runner comparison dropped: a runner replaced after the image no longer
# demotes it.
mutate runner-dropped '\[ ! "\$RUNNER" -nt "\$CLI_CWASM" \]' 'true'
grep -qF '"$RUNNER" -nt "$CLI_CWASM"' "$WORK/runner-dropped" && fail "[runner-dropped] the comparison is still there"
expect_red runner-dropped

# The wasm comparison dropped: a wasm refreshed after the image no longer
# demotes it.
mutate wasm-dropped '\[ ! "\$CLI_WASM" -nt "\$CLI_CWASM" \]' 'true'
grep -qF '"$CLI_WASM" -nt "$CLI_CWASM"' "$WORK/wasm-dropped" && fail "[wasm-dropped] the comparison is still there"
expect_red wasm-dropped

# Existence-only selection, the exact shape the guard regressed to: both
# comparisons gone at once.
mutate existence-only '\[ ! "\$RUNNER" -nt "\$CLI_CWASM" \]' 'true'
sed 's|\[ ! "\$CLI_WASM" -nt "\$CLI_CWASM" \]|true|' "$WORK/existence-only" > "$WORK/existence-only.tmp" \
  && mv "$WORK/existence-only.tmp" "$WORK/existence-only"
grep -qF -- '-nt "$CLI_CWASM"' "$WORK/existence-only" && fail "[existence-only] a comparison is still there"
expect_red existence-only

bash "$GATE" >"$WORK/green.log" 2>&1 || { cat "$WORK/green.log" >&2; fail "the gate FAILED on the unmodified launcher"; }
echo "pick-cli-freshness self-test: ok (3 mutations red, unmodified launcher green)"
