#!/usr/bin/env bash
# Red test for scripts/check_daemon_memory_diagnostic.sh (#2248: a gate means
# nothing until it is shown to FAIL). Each case mutates a COPY of the runner,
# asserts the mutation landed, and asserts the gate then reports failure.
#
# The mutations are the four ways the subject could regress independently --
# the classification, the sidecar, the refusal to keep working, and the
# over-classification that would relabel an ordinary compiler bug.
set -euo pipefail

# #2252: clear anything an outer environment set that the gate itself decides.
unset VIBE_DAEMON_DIAG_RUNNER_JS VIBE_CRASH_DIAG_OUT VIBE_OUTPUT
unset VIBE_WASM_PRE_GROW_PAGES VIBE_IMPORT_ABI

cd "$(dirname "$0")/.."
root="$PWD"
gate="$root/scripts/check_daemon_memory_diagnostic.sh"
runner="$root/scripts/wasm_vibe_host_runner.js"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# Green first: an unmutated runner must PASS, or every red below is vacuous.
if ! "$gate" > "$work/green.log" 2>&1; then
  echo "daemon-memory-diagnostic-test FAIL: the gate does not pass on an unmutated runner"
  sed 's/^/  /' "$work/green.log"
  exit 1
fi

# <name> <python-expression-free old> <new> <expected substring in gate output>
red() { # <name> <old> <new> <want>
  local name="$1" old="$2" new="$3" want="$4"
  local copy="$work/$name.js"
  cp "$runner" "$copy"
  # The mutation must ACTUALLY LAND -- an edit that matches nothing passes the
  # gate while proving nothing, which is the #2248 failure mode itself.
  if ! OLD="$old" NEW="$new" COPY="$copy" python3 -c '
import os, sys
path = os.environ["COPY"]
old = os.environ["OLD"]
new = os.environ["NEW"]
text = open(path).read()
if text.count(old) != 1:
    sys.stderr.write("mutation matched %d times, want 1\n" % text.count(old))
    sys.exit(1)
open(path, "w").write(text.replace(old, new, 1))
'; then
    echo "daemon-memory-diagnostic-test FAIL: $name: the mutation did not land"
    fail=1
    return
  fi
  if VIBE_DAEMON_DIAG_RUNNER_JS="$copy" "$gate" > "$work/$name.log" 2>&1; then
    echo "daemon-memory-diagnostic-test FAIL: $name: the gate PASSED a mutated runner"
    sed 's/^/  /' "$work/$name.log"
    fail=1
    return
  fi
  if ! grep -q "$want" "$work/$name.log"; then
    echo "daemon-memory-diagnostic-test FAIL: $name: gate failed, but not for the seeded reason"
    echo "  wanted: $want"
    sed 's/^/  /' "$work/$name.log"
    fail=1
    return
  fi
  echo "  red ok: $name"
}

# 1. No classification at all -- the bare trap reaches the caller again, which
#    is exactly the state #2876 reported.
red no-classification \
  'error: outOfMemory === null ? decodeExceptionMessage(err) : outOfMemory,' \
  'error: decodeExceptionMessage(err),' \
  'case A'

# 2. Classification that never declines: an ordinary compiler bug gets
#    relabelled "out of memory", sending the reader to recycle their process.
red over-classification \
  'if (daemonHeapLimit - heapPtr >= WASM_PAGE_BYTES) {
        return null;
      }' \
  'if (false) {
        return null;
      }' \
  'case B'

# 3. No sidecar: a caller that tells "compile failed" from "compiler died" by
#    looking for a diagnostic still sees the crash shape.
red no-sidecar \
  'const sidecar =
        process.env.VIBE_CRASH_DIAG_OUT || (args.length >= 2 && args[1] ? `${args[1]}.diag` : "");' \
  'const sidecar = "";' \
  '.diag'

# 4. No refusal: the instance keeps running work it can never complete.
red keeps-working \
  'if (exhausted !== null) {' \
  'if (false) {' \
  'RAN the second request'

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "daemon-memory-diagnostic-test ok (4 mutations, each landed and each caught)"
