#!/usr/bin/env bash
# Red test for check_rc_selfcheck.sh (#2248's rule: a gate means nothing until
# it is known to be able to fail).
#
# The gate's compile path runs for real on a fixture, split over two shards
# (green). The red cases take REAL reports -- the ones the same compile writes
# for that fixture -- and break them the four ways the gate must refuse: a plan
# line that releases more than it holds, a header saying no plan was checked,
# no header at all, and a shard left out. Each mutation is checked for having LANDED before its verdict is
# believed: an edit that matches nothing passes while proving nothing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252).
unset RC_SELFCHECK_ENTRY RC_SELFCHECK_SHARDS RC_SELFCHECK_MAX_SHARDS RC_SELFCHECK_PRE_GROW_PAGES VIBE_RC_SELFCHECK_OUT VIBE_RC_SELFCHECK_SHARD VIBE_RC_SELFCHECK_EXEMPT VIBE_RC_SELFCHECK_LIST RC_SELFCHECK_EXEMPT_FILE

# WHICH COMPILER. The report only exists on a compiler that has the
# self-check, so this cannot answer from the committed seed. The selftests
# lane exports the lane's compiler as VIBE_STAGE2_WASM.
STAGE2_OVERRIDE="${RC_SELFCHECK_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset RC_SELFCHECK_STAGE2
# shellcheck source=resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 rc-selfcheck-test "$STAGE2_OVERRIDE")" || exit 1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_rc_selfcheck_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[rc-selfcheck-test] FAIL: $*" >&2; exit 1; }

# The compiler's own exempt list names compiler functions; the fixture builds
# none of them, so the real list would be stale here. Each case names its own.
: >"$WORK/no_exempt.txt"
export RC_SELFCHECK_EXEMPT_FILE="$WORK/no_exempt.txt"

FIXTURE="fixtures/rc_double_release_bounded_test.vibe"
[ -f "$FIXTURE" ] || fail "the fixture $FIXTURE is gone; pick another fixtures/rc_*.vibe"

# 1. The gate's own compile path, green on a real fixture, over two shards.
if ! RC_SELFCHECK_STAGE2="$STAGE2" RC_SELFCHECK_ENTRY=__no_entry__ RC_SELFCHECK_SHARDS=2 \
  bash scripts/check_rc_selfcheck.sh "$FIXTURE" >"$WORK/green.out" 2>&1; then
  cat "$WORK/green.out" >&2
  fail "the gate refused $FIXTURE, whose plans the corpus gate accepts"
fi
grep -q '^\[rc-selfcheck\] plans=[1-9]' "$WORK/green.out" || { cat "$WORK/green.out" >&2; fail "the green run checked no plan"; }

# 2. Real reports for the same fixture, written by the same compile: shard 0
#    and shard 1 of two.
compile_shard() { # compile_shard <shard> <report>
  VIBE_RC=1 VIBE_INTERNAL_TRUSTED_SOURCE=1 \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SKIP_RUN_INIT=1 \
    VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE=1 VIBE_RC_SELFCHECK_OUT="$2" VIBE_RC_SELFCHECK_SHARD="$1/2" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$STAGE2" "$FIXTURE" "$WORK/out.wasm" __no_entry__ >"$WORK/compile.log" 2>&1 \
    || { cat "$WORK/compile.log" >&2; fail "could not compile $FIXTURE"; }
  [ -s "$2" ] || fail "the compile wrote no report for shard $1"
}
report="$WORK/report.0.txt"
other="$WORK/report.1.txt"
compile_shard 0 "$report"
compile_shard 1 "$other"
bash scripts/check_rc_selfcheck.sh --report "$report" "$other" >/dev/null 2>&1 || fail "the real reports do not pass on their own"

expect_refused() { # expect_refused <label> <report> <needle>
  if bash scripts/check_rc_selfcheck.sh --report "$2" "$other" >"$WORK/red.out" 2>&1; then
    cat "$WORK/red.out" >&2
    fail "$1: the gate accepted it"
  fi
  grep -q "$3" "$WORK/red.out" || { cat "$WORK/red.out" >&2; fail "$1: refused, but not for the reason under test ($3)"; }
}

# 3a. An over-release line, in a real function's name.
fname="$(grep -oE '^fn [A-Za-z_][A-Za-z0-9_]*' "$FIXTURE" | head -n 1 | cut -c4-)"
[ -n "$fname" ] || fail "no function name to put the line on"
cp "$report" "$WORK/over.txt"
printf '%s x 0: owned value released 1 more than held\n' "$fname" >>"$WORK/over.txt"
cmp -s "$report" "$WORK/over.txt" && fail "the over-release line did not land"
expect_refused "over-release" "$WORK/over.txt" "releases more than it holds"

# 3b. A header saying no plan was checked.
sed '1s/^plans [0-9]* of /plans 0 of /' "$report" >"$WORK/zero.txt"
head -n 1 "$WORK/zero.txt" | grep -q '^plans 0 of ' || fail "the zero-plan header did not land"
expect_refused "zero plans" "$WORK/zero.txt" "validated 0 plans"

# 3c. No header at all.
tail -n +2 "$report" >"$WORK/headless.txt"
head -n 1 "$WORK/headless.txt" | grep -q '^plans ' && fail "the header was not removed"
expect_refused "no header" "$WORK/headless.txt" "no 'plans N of M' header"

# 3d. A shard left out: shard 0 alone did not check every plan.
if bash scripts/check_rc_selfcheck.sh --report "$report" >"$WORK/red.out" 2>&1; then
  cat "$WORK/red.out" >&2
  fail "missing shard: the gate accepted shard 0 alone"
fi
grep -q "the shards checked" "$WORK/red.out" || { cat "$WORK/red.out" >&2; fail "missing shard: refused, but not for the reason under test"; }

# 4. The exempt list. A plan moved from checked to `exempt NAME` (header one
#    lower) still covers the compile when the list names it ...
n0="$(head -n 1 "$report" | sed 's/^plans \([0-9]*\) of .*/\1/')"
[ "$n0" -ge 1 ] || fail "shard 0 checked no plan to move"
{ head -n 1 "$report" | sed "s/^plans $n0 of /plans $((n0 - 1)) of /"; tail -n +2 "$report"; echo "exempt $fname"; } >"$WORK/exempt.txt"
head -n 1 "$WORK/exempt.txt" | grep -q "^plans $((n0 - 1)) of " || fail "the exempt header did not land"
echo "$fname" >"$WORK/exempt_list.txt"
RC_SELFCHECK_EXEMPT_FILE="$WORK/exempt_list.txt" bash scripts/check_rc_selfcheck.sh --report "$WORK/exempt.txt" "$other" >"$WORK/ex.out" 2>&1 \
  || { cat "$WORK/ex.out" >&2; fail "a listed exempt plan was not counted toward the compile"; }
grep -q 'exempt=1' "$WORK/ex.out" || { cat "$WORK/ex.out" >&2; fail "the exempt plan was not reported"; }
# ... is refused when the list does not name it ...
expect_refused "unlisted exempt" "$WORK/exempt.txt" "does not list"
# ... and a listed name the compile never built is stale.
echo "no_such_function_in_this_compile" >"$WORK/stale_list.txt"
if RC_SELFCHECK_EXEMPT_FILE="$WORK/stale_list.txt" bash scripts/check_rc_selfcheck.sh --report "$report" "$other" >"$WORK/red.out" 2>&1; then
  cat "$WORK/red.out" >&2
  fail "stale exempt entry: the gate accepted it"
fi
grep -q "delete it from the list" "$WORK/red.out" || { cat "$WORK/red.out" >&2; fail "stale exempt entry: refused, but not for the reason under test"; }

echo "[rc-selfcheck-test] ok"
