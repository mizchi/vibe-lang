#!/usr/bin/env bash
# The launcher's `vibe test` and scripts/vibe_test.sh report a run the same
# way (#3703): the same verdict line per file and the same `[vibe-test]`
# summary, because both count tests with @vibe/testrun's
# `test_run_count_label` and both print @vibe/testrun's summary.
#
#   bash scripts/test_vibe_test_parity.sh <stage2.wasm>
#
# 1. Passing files, a failing one and a file with no test block: identical
#    verdict lines (`(no tests found)` included), and a summary that counts
#    the tests.
# 2. A file that does not compile: identical verdicts, and both summaries are
#    files-only -- a file with no count must not make the total too small.
# 3. The gc backend, which strips the names: neither runner presents its raw
#    over-count as a total, and neither calls a file with tests empty.
# 4. The legacy bump lane (VIBE_RC=0): the same files as 1, the same answers.
#    The launcher used to refuse the file with no functions there (#3706).
#
# The failure report under a FAIL line is not compared: the launcher's and the
# script's differ by design (@vibe/testreport's launcher and script reports).
#
# VIBE_TEST_PARITY_LAUNCHER / VIBE_TEST_PARITY_SCRIPT replace the two runners;
# scripts/test_vibe_test_parity_test.sh points them at mutants to prove this
# gate fails.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_vibe_test_parity.sh <stage2.wasm>" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
# Every case names its lane: tests/gates/lib.sh exports VIBE_RC=0, so an
# inherited value would silently turn cases 1-3 into a second run of case 4.
unset VIBE_TEST_BACKEND VIBE_BACKEND VIBE_RC VIBE_TEST_RESULTS VIBE_TEST_NESTED VIBE_TEST_JOBS || true
LAUNCHER="${VIBE_TEST_PARITY_LAUNCHER:-$ROOT_DIR/runtime/vibe}"
SCRIPT="${VIBE_TEST_PARITY_SCRIPT:-$ROOT_DIR/scripts/vibe_test.sh}"

WORK_REL="_build/vibe_test_parity.$$"
WORK="$ROOT_DIR/$WORK_REL"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/vibe-test-parity.XXXXXX")"
mkdir -p "$WORK"
trap 'rm -rf "$WORK" "$OUT"' EXIT
fail() { echo "[vibe-test-parity] FAIL $*" >&2; exit 1; }

printf 'test "one" {\n  assert(1 + 1 == 2)\n}\ntest "two" {\n  assert(true)\n}\n' > "$WORK/two_test.vibe"
printf 'test "only" {\n  assert(2 - 1 == 1)\n}\n' > "$WORK/one_test.vibe"
printf 'test "bad" {\n  assert(1 + 1 == 3)\n}\n' > "$WORK/bad_test.vibe"
printf 'fn helper(x: Int) -> Int {\n  x + 1\n}\n' > "$WORK/helper_test.vibe"
printf 'test "broken" {\n  assert(undefined_name == 1)\n}\n' > "$WORK/broken_test.vibe"

via_launcher() { # <name> <files...>
  local name="$1"; shift
  VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_BUILD_DIR="$OUT/build.$name" \
    bash "$LAUNCHER" test --no-cache "$@" > "$OUT/$name.launcher" 2>&1 || true
}
via_script() { # <name> <files...>
  local name="$1"; shift
  VIBE_TEST_CLI_WASM="$CLI" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash "$SCRIPT" "$@" > "$OUT/$name.script" 2>&1 || true
}
# The verdict lines, sorted (the script's workers finish in any order), and the
# `[vibe-test]` lines: the summary and its notes. (The script's compiler notice
# is silenced by VIBE_TEST_QUIET_COMPILER_NOTE.)
verdicts() { grep -E '^(ok|FAIL)' "$1" | sed 's/ (cached)$//' | LC_ALL=C sort; }
summary() { grep '^\[vibe-test\]' "$1" || true; }
compare() { # <name>
  local name="$1"
  verdicts "$OUT/$name.launcher" > "$OUT/$name.lv"
  verdicts "$OUT/$name.script" > "$OUT/$name.sv"
  [ -s "$OUT/$name.lv" ] || { cat "$OUT/$name.launcher" >&2; fail "$name: the launcher printed no verdict"; }
  diff -u "$OUT/$name.sv" "$OUT/$name.lv" >&2 || { cat "$OUT/$name.launcher" "$OUT/$name.script" >&2; fail "$name: the verdict lines differ (script -, launcher +)"; }
  summary "$OUT/$name.launcher" > "$OUT/$name.ls"
  summary "$OUT/$name.script" > "$OUT/$name.ss"
  diff -u "$OUT/$name.ss" "$OUT/$name.ls" >&2 || { cat "$OUT/$name.launcher" "$OUT/$name.script" >&2; fail "$name: the summaries differ (script -, launcher +)"; }
}

# --- 1. counted ---------------------------------------------------------------
set1=("$WORK_REL/two_test.vibe" "$WORK_REL/one_test.vibe" "$WORK_REL/bad_test.vibe" "$WORK_REL/helper_test.vibe")
via_launcher counted "${set1[@]}"
via_script counted "${set1[@]}"
compare counted
grep -qxF "[vibe-test] 3 passed, 1 failed (4 files, 4 tests)" "$OUT/counted.ls" \
  && grep -qxF "[vibe-test] note: 1 file(s) with no tests found" "$OUT/counted.ls" \
  || { cat "$OUT/counted.launcher" >&2; fail "the summary does not count 4 tests in 4 files"; }
grep -qxF "ok   $WORK_REL/helper_test.vibe (no tests found)" "$OUT/counted.lv" || fail "a file without tests is not noted"
grep -q 'no tests found' <(grep -v helper_test "$OUT/counted.lv") && fail "a file with tests is noted as having none"

# --- 2. a compile failure -----------------------------------------------------
set2=("$WORK_REL/two_test.vibe" "$WORK_REL/broken_test.vibe")
via_launcher broken "${set2[@]}"
via_script broken "${set2[@]}"
compare broken
grep -qxF "[vibe-test] 1 passed, 1 failed (2 files)" "$OUT/broken.ls" \
  || { cat "$OUT/broken.launcher" >&2; fail "a compile failure did not leave the summary files-only"; }

# --- 3. the gc backend --------------------------------------------------------
if command -v wasmtime >/dev/null 2>&1; then
  set3=("$WORK_REL/two_test.vibe" "$WORK_REL/one_test.vibe")
  VIBE_TEST_BACKEND=gc via_launcher gc "${set3[@]}"
  VIBE_TEST_BACKEND=gc via_script gc "${set3[@]}"
  compare gc
  grep -qxF "[vibe-test] 2 passed, 0 failed (2 files)" "$OUT/gc.ls" \
    || { cat "$OUT/gc.launcher" >&2; fail "the gc summary presents a total it cannot count"; }
  grep -q 'no tests found' "$OUT/gc.lv" && fail "a gc file with tests is noted as having none"
else
  echo "[vibe-test-parity] note: wasmtime not found; the gc case was not run" >&2
fi

# --- 4. the legacy bump lane ---------------------------------------------------
VIBE_RC=0 via_launcher bump "${set1[@]}"
VIBE_RC=0 via_script bump "${set1[@]}"
compare bump
diff -u "$OUT/counted.ls" "$OUT/bump.ls" >&2 || fail "the bump lane's summary differs from the default lane's"
grep -qxF "ok   $WORK_REL/helper_test.vibe (no tests found)" "$OUT/bump.lv" \
  || { cat "$OUT/bump.launcher" >&2; fail "the bump lane does not report a file without functions as having no tests (#3706)"; }

echo "[vibe-test-parity] ok (the same verdicts and summaries from both runners: counted, a compile failure files-only, gc uncounted, the bump lane)"
