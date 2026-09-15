#!/usr/bin/env bash
# Red test for scripts/check_host_remove_parity.sh (#2248: a gate is worth
# nothing until it is known to be able to FAIL).
#
# The mutation is the defect itself: restore the JS runner's `fs_remove` to the
# recursive `rmSync(.., { recursive: true, force: true })` it was before #2758,
# on a COPY, and point the gate at that copy. The gate must then report that the
# two runners disagree about `Fs::remove` on a directory.
#
# Two things this asserts BEFORE trusting the failure, because a red test that
# matches nothing passes while proving nothing (AGENTS.md):
#
#   1. the mutation actually changed the file;
#   2. the UNmutated gate passes on the same inputs, so the failure is
#      attributable to the mutation and not to a broken environment (#2252).
#
# It also unsets the variables it depends on, so an exported value from a shell
# hook cannot silently turn a case into a no-op (#2252 again).
set -euo pipefail

unset HOST_REMOVE_PARITY_JS_RUNNER
unset HOST_REMOVE_PARITY_WORK

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_host_remove_parity.sh"
WORK="_build/_gate_host_remove_parity_selftest"
rm -rf "$WORK"; mkdir -p "$WORK"

fail() { echo "host-remove-parity-selftest: FAIL: $*" >&2; exit 1; }

# --- GREEN: the gate passes on the tree as committed. -----------------------
if ! HOST_REMOVE_PARITY_WORK="$WORK/green" bash "$GATE" >"$WORK/green.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/green.log" >&2
  fail "the gate does not pass on the unmutated tree, so a later failure would prove nothing"
fi

# --- the mutation -----------------------------------------------------------
MUT="$WORK/wasm_vibe_host_runner.js"
cp scripts/wasm_vibe_host_runner.js "$MUT"
python3 - "$MUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """      fs_remove(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.unlinkSync(filePath);
          return 0n;
        } catch (e) {
          throwVibeHostError(`fs_remove failed for '${filePath}': ${e.message}`);
        }
      },"""
if old not in s:
    sys.stderr.write("host-remove-parity-selftest: the mutation target is not present -- "
                     "fs_remove no longer has the shape this test reverts. Update the test.\n")
    sys.exit(2)
new = """      fs_remove(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.rmSync(filePath, { recursive: true, force: true });
          return 0n;
        } catch (e) {
          return 0n;
        }
      },"""
open(p, "w").write(s.replace(old, new))
PY

# 1. the mutation landed.
if ! grep -q "recursive: true, force: true" "$MUT"; then
  fail "the mutation did not land in the copied runner"
fi
if ! node --check "$MUT" >/dev/null 2>&1; then
  fail "the mutated runner does not parse, so the gate would fail for the wrong reason"
fi

# --- RED: the gate must reject the mutated runner. --------------------------
if HOST_REMOVE_PARITY_WORK="$WORK/red" HOST_REMOVE_PARITY_JS_RUNNER="$ROOT_DIR/$MUT" \
   bash "$GATE" >"$WORK/red.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/red.log" >&2
  fail "the gate PASSED with a recursive JS fs_remove -- it cannot see the divergence it exists to catch"
fi

# And it must fail for the RIGHT reason: the directory probe, naming both sides.
if ! grep -q "remove_dir" "$WORK/red.log"; then
  echo "--- gate output ---" >&2; cat "$WORK/red.log" >&2
  fail "the gate failed, but not on the remove_dir probe -- the failure is not attributable to the mutation"
fi

rm -rf "$WORK"
echo "host-remove-parity-selftest: ok (green on the tree; red on a recursive JS fs_remove, reported against remove_dir)"
