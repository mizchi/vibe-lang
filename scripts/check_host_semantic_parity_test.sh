#!/usr/bin/env bash
# Red test for check_host_semantic_parity.sh (#2248: a gate means nothing until
# it is shown to be able to FAIL).
#
# The mutation is the JS RUNNER, because the gate's subject is the two runners
# disagreeing -- a mutation anywhere else would not produce the divergence this
# exists to catch. `fs_read_file`'s catch branch is made to return an empty
# string instead of throwing, which is the most plausible real version of this
# bug: a provider that treats "missing" as "empty" looks correct in every
# happy-path test and silently turns a missing-config error into a default.
#
# Environment: every variable the gate reads is unset first (#2252), then set
# explicitly per case.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LANE_STAGE2="${HOST_SEMANTIC_PARITY_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset HOST_SEMANTIC_PARITY_STAGE2 HOST_SEMANTIC_PARITY_JS_RUNNER HOST_SEMANTIC_PARITY_WORK || true

GATE="$ROOT_DIR/scripts/check_host_semantic_parity.sh"
WORK="_build/_gate_host_semantic_parity_selftest"
rm -rf "$WORK"; mkdir -p "$WORK"

fail() { echo "host-semantic-parity-selftest: FAIL: $1" >&2; rm -rf "$WORK"; exit 1; }

# A CHECK, not a measurement, so the degrading resolver is the right one here
# (AGENTS.md draws exactly this line): a check is usually better run against
# something than not run, and both phases below compare the SAME compiler
# against itself with only the runner differing. `resolve_stage2` announces on
# stderr which one it settled on.
if [ -z "$LANE_STAGE2" ] || [ ! -f "$LANE_STAGE2" ]; then
  . "$ROOT_DIR/scripts/resolve_stage2.sh"
  LANE_STAGE2="$(resolve_stage2 host-semantic-parity-selftest "" || true)"
fi
if [ -z "$LANE_STAGE2" ] || [ ! -f "$LANE_STAGE2" ]; then
  fail "no stage2 to run either phase against; pass HOST_SEMANTIC_PARITY_STAGE2=<stage2.wasm>"
fi

# --- GREEN: the gate passes on the tree. ------------------------------------
if ! HOST_SEMANTIC_PARITY_STAGE2="$LANE_STAGE2" HOST_SEMANTIC_PARITY_WORK="$WORK/green" \
     bash "$GATE" >"$WORK/green.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/green.log" >&2
  fail "the gate does not pass on an unmutated tree, so a red below would prove nothing"
fi

# --- build the mutated runner ------------------------------------------------
MUT="$WORK/mutated_runner.js"
cp "$ROOT_DIR/scripts/wasm_vibe_host_runner.js" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        } catch (e) {
          throwVibeHostError(`fs_read_file failed for '${filePath}': ${e.message}`);
        }"""
if old not in s:
    sys.stderr.write("host-semantic-parity-selftest: the mutation target is not present -- "
                     "fs_read_file's catch no longer has the shape this test rewrites. "
                     "Update the test.\n")
    sys.exit(2)
new = """        } catch (e) {
          return encodeHostString(instanceRef, "");
        }"""
open(p, "w").write(s.replace(old, new, 1))
PY
case $? in 0) ;; *) fail "could not build the mutated runner" ;; esac

# The mutation must have LANDED and must still parse -- a gate that fails
# because the runner is syntactically broken proves nothing about divergence.
if ! grep -q 'return encodeHostString(instanceRef, "");' "$MUT"; then
  fail "the mutation did not land in the copied runner"
fi
if ! node --check "$MUT" >/dev/null 2>&1; then
  fail "the mutated runner does not parse, so the gate would fail for the wrong reason"
fi

# --- RED: the gate must reject the mutated runner. --------------------------
if HOST_SEMANTIC_PARITY_STAGE2="$LANE_STAGE2" HOST_SEMANTIC_PARITY_WORK="$WORK/red" \
   HOST_SEMANTIC_PARITY_JS_RUNNER="$ROOT_DIR/$MUT" \
   bash "$GATE" >"$WORK/red.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/red.log" >&2
  fail "the gate PASSED with a JS fs_read_file that returns '' for a missing file"
fi

# And for the RIGHT reason: the `missing` probe, naming both sides.
if ! grep -q "'missing'" "$WORK/red.log"; then
  echo "--- gate output ---" >&2; cat "$WORK/red.log" >&2
  fail "the gate failed, but not on the 'missing' probe -- not attributable to the mutation"
fi

rm -rf "$WORK"
echo "host-semantic-parity-selftest: ok (green on the tree; red when JS turns a missing file into an empty one, reported against 'missing')"
