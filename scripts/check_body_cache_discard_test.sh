#!/usr/bin/env bash
# Red test for check_body_cache_discard.sh (#2248).
#
# Four cases, each mutation checked for having LANDED before its verdict is
# believed. RED 1 is the one that matters -- it is the exact shape the rule
# exists to stop coming back.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252).
unset VIBE_BODY_CACHE_DISCARD_ROOT
unset VIBE_BODY_CACHE_DISCARD_ROOT_DIR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_bodycache_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[body-cache-discard-test] FAIL: $*" >&2; exit 1; }
run_gate() { VIBE_BODY_CACHE_DISCARD_ROOT_DIR="$1" bash scripts/check_body_cache_discard.sh >"$WORK/out" 2>&1; }

# GREEN control on the real tree. Without it a gate failing for an unrelated
# reason would make every red case below "pass".
if ! run_gate lib; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the real tree; the red cases below would prove nothing"
fi

# RED 1: the regression itself -- a production file passing two fresh caches.
mkdir -p "$WORK/r1/pkg"
cat > "$WORK/r1/pkg/regressed.vibe" <<'VIBE'
fn build(stmts: Array[Stmt]) -> Bytes with Exception {
  compile_wasi_module_linked_impl(stmts, "main", codegen_body_cache_new(), codegen_body_cache_new(), 0, 0 - 1)
}
VIBE
grep -qF 'codegen_body_cache_new(), codegen_body_cache_new()' "$WORK/r1/pkg/regressed.vibe" \
  || fail "RED 1 mutation did not land (the doubled new() is not in the probe)"
if run_gate "$WORK/r1"; then
  fail "RED 1: the gate accepted a production file passing a fresh cache as the OUT parameter"
fi
grep -qF 'passes a fresh cache as the OUT parameter' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 1b (control): the SAME file with the OUT cache discarded must pass. This
# is what would catch a rule that rejects every mention of the cache rather than
# the doubled inline form.
mkdir -p "$WORK/r1b/pkg"
sed 's/codegen_body_cache_new(), codegen_body_cache_new()/codegen_body_cache_new(), codegen_body_cache_discard()/' \
  "$WORK/r1/pkg/regressed.vibe" > "$WORK/r1b/pkg/repaired.vibe"
grep -qF 'codegen_body_cache_discard()' "$WORK/r1b/pkg/repaired.vibe" \
  || fail "RED 1b mutation did not land (the repair was not applied)"
run_gate "$WORK/r1b" \
  || { cat "$WORK/out" >&2; fail "RED 1b: the repaired form is rejected; the rule is not about the doubled new()"; }

# RED 2: the TEST exemption is real. The same offending file under a tests/
# directory must pass -- a test that passes two fresh caches is exercising the
# recording path on purpose.
mkdir -p "$WORK/r2/pkg/tests"
cp "$WORK/r1/pkg/regressed.vibe" "$WORK/r2/pkg/tests/regressed_test.vibe"
run_gate "$WORK/r2" \
  || { cat "$WORK/out" >&2; fail "RED 2: the tests/ exemption does not apply"; }

# RED 3: an empty scan. Silence is "unchecked", not "clean".
mkdir -p "$WORK/r3"
if run_gate "$WORK/r3"; then
  fail "RED 3: the gate passed having scanned nothing"
fi
grep -qF 'no .vibe files scanned' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

echo "[body-cache-discard-test] ok (3 red cases + 2 controls, each mutation verified to land)"
