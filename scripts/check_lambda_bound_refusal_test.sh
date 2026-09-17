#!/usr/bin/env bash
# Red test for check_lambda_bound_refusal.sh after #2778 deleted the walk.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

unset LAMBDA_BOUND_REFUSAL_FIXTURES
unset VIBE_LAMBDA_BOUND_REFUSAL_ROOT
unset LAMBDA_BOUND_ERASED_GLOB
unset LAMBDA_BOUND_NESTED_OK
STAGE2_OVERRIDE="${LAMBDA_BOUND_REFUSAL_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset LAMBDA_BOUND_REFUSAL_STAGE2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_lbr_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[lambda-bound-refusal-test] FAIL: $*" >&2; exit 1; }

run_gate() {
  if [ -n "$STAGE2_OVERRIDE" ]; then
    LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
      bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1
  else
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1
  fi
}

if ! run_gate; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated tree; the red cases below would prove nothing"
fi

# Planted files live under the repo so the wasm preopen can read them.
PLANT="$ROOT_DIR/_build/_lambda_bound_refusal_selftest"
rm -rf "$PLANT"
mkdir -p "$PLANT/r1" "$PLANT/r2"
trap 'rm -rf "$WORK" "$PLANT"' EXIT

# RED 1: the deleted approximation corpus returns.
printf 'export fn _start() -> Int { 0 }\n' > "$PLANT/r1/lambda_bound_erased_interp_back_refused.vibe"
if [ -n "$STAGE2_OVERRIDE" ]; then
  LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
    LAMBDA_BOUND_ERASED_GLOB="$PLANT/r1/lambda_bound_erased_interp*refused.vibe" \
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1 && r1=1 || r1=0
else
  LAMBDA_BOUND_ERASED_GLOB="$PLANT/r1/lambda_bound_erased_interp*refused.vibe" \
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1 && r1=1 || r1=0
fi
[ "$r1" -eq 0 ] || fail "RED 1: the gate passed with an erased-interp refusal fixture present"
grep -qF 'must not return' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 2: the nested shim control does not compile.
printf 'export fn _start() -> Int { no_such_function_anywhere(1) }\n' > "$PLANT/r2/bad.vibe"
if [ -n "$STAGE2_OVERRIDE" ]; then
  LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
    LAMBDA_BOUND_NESTED_OK="$PLANT/r2/bad.vibe" \
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1 && r2=1 || r2=0
else
  LAMBDA_BOUND_NESTED_OK="$PLANT/r2/bad.vibe" \
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1 && r2=1 || r2=0
fi
[ "$r2" -eq 0 ] || fail "RED 2: the gate passed a nested shim control that does not compile"
grep -qF 'did not compile' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

# RED 3: the nested shim control is missing.
if [ -n "$STAGE2_OVERRIDE" ]; then
  LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
    LAMBDA_BOUND_NESTED_OK="$PLANT/r3/missing.vibe" \
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1 && r3=1 || r3=0
else
  LAMBDA_BOUND_NESTED_OK="$PLANT/r3/missing.vibe" \
    bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1 && r3=1 || r3=0
fi
[ "$r3" -eq 0 ] || fail "RED 3: the gate passed with a missing nested shim control"
grep -qF 'missing' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

echo "[lambda-bound-refusal-test] ok (3 red cases, each mutation verified to land)"
