#!/usr/bin/env bash
# Self-test for scripts/test_vibe_test_parity.sh: the gate must FAIL when
# either runner reports a run differently, and when both drift the same way.
#
#   bash scripts/test_vibe_test_parity_test.sh <stage2.wasm>
#
# Each mutant wraps a real runner and rewrites one thing it prints. It writes
# a marker whenever the rewrite changed the output, and each case first checks
# that marker: a mutation that matched nothing would let the gate "fail"
# for some other reason, or pass, while proving nothing.
#
# 1. The launcher's summary loses its test total: the summaries differ.
# 2. The script's `(no tests found)` note is dropped: the verdicts differ.
# 3. Both runners lose the test total: they agree, and the gate's own
#    assertion that 4 tests were counted catches it.
# 4. Control: the real runners pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_vibe_test_parity_test.sh <stage2.wasm>" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
unset VIBE_TEST_PARITY_LAUNCHER VIBE_TEST_PARITY_SCRIPT || true

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-test-parity-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[vibe-test-parity-test] FAIL $*" >&2; exit 1; }

# mutant <name> <real runner> <sed expression>
mutant() {
  cat > "$WORK/$1.sh" <<MUT
#!/usr/bin/env bash
rc=0
bash "$2" "\$@" > "$WORK/$1.raw" 2>&1 || rc=\$?
sed -E '$3' "$WORK/$1.raw" > "$WORK/$1.out"
cmp -s "$WORK/$1.raw" "$WORK/$1.out" || : > "$WORK/$1.applied"
cat "$WORK/$1.out"
exit \$rc
MUT
}
mutant launcher_total "$ROOT_DIR/runtime/vibe" 's/ files, [0-9]+ tests\)$/ files)/'
mutant script_note "$ROOT_DIR/scripts/vibe_test.sh" 's/ \(no tests found\)$//'
mutant launcher_both "$ROOT_DIR/runtime/vibe" 's/ files, [0-9]+ tests\)$/ files)/'
mutant script_both "$ROOT_DIR/scripts/vibe_test.sh" 's/ files, [0-9]+ tests\)$/ files)/'

expect_fail() { # <case> <expected message> <env...>
  local case_name="$1" want="$2"; shift 2
  rm -f "$WORK"/*.applied
  if env "$@" bash "$ROOT_DIR/scripts/test_vibe_test_parity.sh" "$CLI" > "$WORK/$case_name.log" 2>&1; then
    fail "$case_name: the gate passed a mutant"
  fi
  grep -qF "$want" "$WORK/$case_name.log" || { cat "$WORK/$case_name.log" >&2; fail "$case_name: the gate failed, but not with '$want'"; }
}

expect_fail launcher_total "counted: the summaries differ" VIBE_TEST_PARITY_LAUNCHER="$WORK/launcher_total.sh"
[ -e "$WORK/launcher_total.applied" ] || fail "launcher_total: the mutation changed nothing"

expect_fail script_note "counted: the verdict lines differ" VIBE_TEST_PARITY_SCRIPT="$WORK/script_note.sh"
[ -e "$WORK/script_note.applied" ] || fail "script_note: the mutation changed nothing"

expect_fail both_total "does not count 4 tests" \
  VIBE_TEST_PARITY_LAUNCHER="$WORK/launcher_both.sh" VIBE_TEST_PARITY_SCRIPT="$WORK/script_both.sh"
[ -e "$WORK/launcher_both.applied" ] && [ -e "$WORK/script_both.applied" ] || fail "both_total: a mutation changed nothing"

bash "$ROOT_DIR/scripts/test_vibe_test_parity.sh" "$CLI" > "$WORK/control.log" 2>&1 \
  || { cat "$WORK/control.log" >&2; fail "control: the gate failed on the real runners"; }

echo "[vibe-test-parity-test] ok (a launcher summary, a script verdict and a shared drift are each caught; the real runners pass)"
