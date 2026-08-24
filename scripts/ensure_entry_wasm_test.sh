#!/usr/bin/env bash
# Self-test for scripts/ensure_entry_wasm.sh's FAILURE path, and for the two
# callers that consume its exit code (#2271).
#
# The bug it pins: the compile line ran as a bare command under `set -e`, so a
# non-zero runner abandoned the script one line above the `[ -s ... ] || echo
# ... exit 1` that existed to explain the failure. Callers got exit 1 and an
# empty stderr -- which is exactly what `vibe fmt --check` means by "not
# formatted" -- so `vibe fmt` looped forever on a file that was never at fault,
# with the real cause sitting in the `<wasm>.diag` sidecar that nothing read.
#
# Everything here works on scratch entries under _build/, never on the real
# formatter artifact, so it cannot leave the tree in a state another gate
# section would trip over.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_REL="_build/ensure_entry_wasm_test"
WORK="$ROOT_DIR/$WORK_REL"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[ensure-entry-wasm-test] FAIL: $*" >&2; exit 1; }

# --- 1. a compile failure is LOUD, and names the compiler's own diagnostic ---
printf 'fn f( -> Int {\n' > "$WORK/bad.vibe"
rc=0
bash scripts/ensure_entry_wasm.sh "$WORK_REL/bad.vibe" "$WORK_REL/bad.wasm" \
  >"$WORK/bad.out" 2>"$WORK/bad.err" || rc=$?
[ "$rc" = "1" ] || fail "unbuildable entry exited $rc, want 1"
grep -q "failed to compile $WORK_REL/bad.vibe" "$WORK/bad.err" \
  || fail "stderr does not name the entry it could not compile"
# The compiler's own words, not just "it failed" -- that is the difference
# between an actionable message and the silent exit this test exists for.
grep -q "expected parameter name" "$WORK/bad.err" \
  || fail "stderr does not carry the compiler's diagnostic"
grep -q "ensure_generated.sh" "$WORK/bad.err" \
  || fail "stderr does not point at the usual cause on a fresh checkout"
[ ! -e "$WORK/bad.wasm" ] || fail "a failed compile left an artifact behind"

# --- 2. a failed REBUILD removes the previous artifact ---
# Otherwise the caller keeps answering from a formatter built before the edit,
# which is the stale-reuse ensure_entry_wasm.sh's staleness rules exist to
# prevent. The bogus wasm stands in for a good build from an earlier run.
printf 'stale artifact\n' > "$WORK/stale.wasm"
printf '%s\n' "$WORK_REL/stale.vibe" > "$WORK/stale.wasm.deps"
printf 'fn g( -> Int {\n' > "$WORK/stale.vibe"
# Backdate the artifact rather than trusting write order: everything here is
# written inside one second, and the staleness tests are strict `-nt`, so
# same-second mtimes read as fresh and nothing would rebuild at all.
touch -t 200001010000 "$WORK/stale.wasm" "$WORK/stale.wasm.deps"
rc=0
bash scripts/ensure_entry_wasm.sh "$WORK_REL/stale.vibe" "$WORK_REL/stale.wasm" \
  >/dev/null 2>"$WORK/stale.err" || rc=$?
[ "$rc" = "1" ] || fail "failed rebuild exited $rc, want 1"
[ ! -e "$WORK/stale.wasm" ] || fail "failed rebuild left the previous artifact in place"

# --- 3. the success path still works, and still prints the path ---
printf 'fn main() -> Int {\n  0\n}\n' > "$WORK/good.vibe"
out="$(bash scripts/ensure_entry_wasm.sh "$WORK_REL/good.vibe" "$WORK_REL/good.wasm" 2>/dev/null)"
[ "$out" = "$WORK_REL/good.wasm" ] || fail "success printed '$out', want '$WORK_REL/good.wasm'"
[ -s "$WORK/good.wasm" ] || fail "success produced no wasm"
[ -s "$WORK/good.wasm.deps" ] || fail "success captured no dependency closure"

# --- 4. the callers must not swallow that exit code in a bare assignment ---
# `var="$(bash .../ensure_...)"` under `set -e` dies with exit 1 and nothing on
# stderr, which is indistinguishable from a formatting verdict. Each caller has
# to handle the failure explicitly.
assert_handles() {
  local file="$1" ensure="$2"
  grep -qE "^[a-z_]+=\"\\\$\(bash \"\\\$ROOT_DIR/scripts/$ensure\"\)\"\$" "$file" \
    && return 1
  grep -q "scripts/$ensure" "$file" || return 2
  return 0
}
for pair in "scripts/vibe_fmt.sh ensure_vibe_fmt_entry.sh" \
            "scripts/run_vibe_fmt_batch.sh ensure_vibe_fmt_batch.sh"; do
  set -- $pair
  case "$(assert_handles "$1" "$2" && echo 0 || echo $?)" in
    0) ;;
    1) fail "$1 calls $2 in a bare assignment; a build failure exits 1 with no message" ;;
    2) fail "$1 no longer calls $2 -- update this test" ;;
  esac
done

# Red-test rule 4 against a mutated copy: a checker that cannot fail is not a
# check. Restoring the bare form must be rejected.
mkdir -p "$WORK/mut/scripts"
sed 's/^entry_wasm_rel=.*$/entry_wasm_rel="$(bash "$ROOT_DIR\/scripts\/ensure_vibe_fmt_entry.sh")"/' \
  scripts/vibe_fmt.sh > "$WORK/mut/scripts/vibe_fmt.sh"
grep -q 'ensure_vibe_fmt_entry' "$WORK/mut/scripts/vibe_fmt.sh" \
  || fail "red-test mutation lost the call it was supposed to reintroduce"
if assert_handles "$WORK/mut/scripts/vibe_fmt.sh" "ensure_vibe_fmt_entry.sh"; then
  fail "rule 4 accepts the bare assignment it exists to reject"
fi

echo "[ensure-entry-wasm-test] ok (loud failure + diagnostic + stale removal + success path + caller exit-code handling, red-tested)"
