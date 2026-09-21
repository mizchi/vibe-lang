#!/usr/bin/env bash
# check_grep_chunked_sweep_test.sh -- prove check_grep_chunked_sweep.sh can FAIL.
#
# #2248: a gate that has never been seen to fail certifies nothing.
#
# These mutations hit the DRIVER, not the gate. That is the difference from
# the sibling budget self-test, and it is deliberate: the gate's claim is that
# `vibe_grep_bin.sh` stitches chunks back together without changing the
# answer, so the mutations break the stitching in the three ways it could
# plausibly break -- drop a chunk, drop a line from each chunk, and emit one
# JSON array per chunk instead of one for the sweep. A gate that still passed
# with any of those in place would not be testing stitching at all.
#
# Each mutation is asserted to have CHANGED the file before the gate runs. An
# edit that matches nothing leaves a pristine driver, the gate passes, and the
# pass would be recorded as proof -- which has happened in this repo before.
#
#   GREP_CHUNK_STAGE2=<stage2.wasm> bash scripts/check_grep_chunked_sweep_test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_grep_chunked_sweep.sh"
DRIVER="scripts/vibe_grep_bin.sh"
[ -f "$GATE" ] || { echo "grep-chunked-sweep-test: missing $GATE" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "grep-chunked-sweep-test: missing $DRIVER" >&2; exit 1; }

# #2252: inherit nothing. A variable the session hook exported would steer
# these runs, and a case that no-ops looks exactly like a case that passed.
unset VIBE_GREP_CHUNK_FILES
unset VIBE_GREP_MEMORY_BUDGET_MB
unset VIBE_GREP_MEMORY_SAFETY_FACTOR
unset VIBE_CLI_WASM
unset VIBE_REVIEW_LINT_GREP_BIN

# Resolve ONCE and hand it down. The gate refuses without a compiler that has
# the chunk mode, and a refusal would redden every mutation for a reason that
# has nothing to do with the mutation -- the failure this file exists to rule
# out.
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2_strict grep-chunked-sweep-test "${GREP_CHUNK_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
export GREP_CHUNK_STAGE2="$STAGE2"

BACKUP="$(mktemp)"
cp "$DRIVER" "$BACKUP"
restore() { cp "$BACKUP" "$DRIVER"; rm -f "$BACKUP"; }
trap restore EXIT

passed=0
fail() { echo "grep-chunked-sweep-test: FAIL: $*" >&2; exit 1; }

expect_red() { # <name> <sed-expr>
  local name="$1" expr="$2" status=0
  cp "$BACKUP" "$DRIVER"
  sed -i.bak "$expr" "$DRIVER"
  rm -f "$DRIVER.bak"
  if cmp -s "$BACKUP" "$DRIVER"; then
    cp "$BACKUP" "$DRIVER"
    fail "$name: the mutation changed NOTHING, so this case proves nothing"
  fi
  bash "$GATE" >/dev/null 2>&1 || status=$?
  cp "$BACKUP" "$DRIVER"
  if [ "$status" = "0" ]; then
    fail "$name: the mutated driver PASSED the gate; that property is not
actually being checked"
  fi
  echo "grep-chunked-sweep-test: ok -- $name reddens the gate (exit $status)"
  passed=$((passed + 1))
}

# Unmutated first, or every case below is red for an unrelated reason.
status=0
bash "$GATE" >/dev/null 2>&1 || status=$?
[ "$status" = "0" ] || fail "the UNMUTATED gate does not pass (exit $status).
Run it directly to see why; until it passes, no mutation below proves anything."
echo "grep-chunked-sweep-test: ok -- the unmutated gate passes"

# A chunk whose output is dropped entirely. The sweep still exits 0 and still
# prints most of the answer, which is precisely the silent loss the gate is
# for.
expect_red "a dropped chunk" 's|^          cat "\$out"$|          head -n -1 "$out" > /dev/null; true|'

# Every chunk loses its last line: a boundary-shaped loss rather than a whole
# chunk, so a gate comparing only match COUNTS on one chunk size could miss it.
expect_red "each chunk loses its last line" 's|^          cat "\$out"$|          sed "$d" "$out"|'

# JSON emitted per chunk instead of reassembled: several arrays in one answer.
# `#` as the delimiter: the target line contains a `|` pipe, which would end
# a `|`-delimited expression early and make sed reject it -- which is what the
# first version of this case did, and why every mutation asserts it landed.
expect_red "JSON per chunk instead of one array" \
  '/jsonbody"$/s#.*#          cat "$out" >> "$jsonbody"#'

echo "grep-chunked-sweep-test: ok ($passed mutations reddened the gate)"
