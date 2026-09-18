#!/usr/bin/env bash
# Red test for scripts/ensure_generated.sh (#2248: a check means nothing until
# it is known to be able to fail -- and this one could not even RUN).
#
# The staleness report printed its input diff through `| head -20`. On a diff
# longer than that, `head` closes the pipe, `printf` takes SIGPIPE, and
# `set -o pipefail` + `set -e` turn that into exit 141 BEFORE any artifact is
# regenerated. A tree more than 20 inputs behind therefore could not heal
# itself: every invocation died on the same line, said nothing about it, and
# left the stale bundles in place. Measured: a bundle five days older than the
# tree, whose `lib/@vibe/core/set.vibe` still had the pre-#2840 `add_by`, which
# the compiler then correctly refused -- reported as a self-compile failure
# with no connection to its cause.
#
# So the property is: a LONG staleness diff must still regenerate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STAMP="lib/@vibe/compiler/.generated.stamp"
INPUTS="lib/@vibe/compiler/.generated.inputs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ensure_generated_selftest.XXXXXX")"
trap 'rm -rf "$WORK"; [ -f "$WORK.stamp" ] && mv "$WORK.stamp" "$STAMP" || true; [ -f "$WORK.inputs" ] && mv "$WORK.inputs" "$INPUTS" || true' EXIT

fail() { echo "ensure-generated-selftest: FAIL: $*" >&2; exit 1; }

# GREEN control: the tree as committed is answerable at all.
if ! bash scripts/ensure_generated.sh >"$WORK/green.log" 2>&1; then
  cat "$WORK/green.log" >&2
  fail "the script does not succeed on the tree as committed; the red case below would prove nothing"
fi

# RED: a stamped input list that differs on FAR more than 20 lines.
[ -f "$INPUTS" ] || fail "no stamped input list after a successful run; the mutation has nothing to perturb"
cp "$STAMP" "$WORK.stamp" 2>/dev/null || true
cp "$INPUTS" "$WORK.inputs"
awk '{ print "0000000000000000000000000000000000000000000000000000000000000000  " $2 }' "$WORK.inputs" > "$INPUTS"
differing="$(diff "$INPUTS" "$WORK.inputs" | grep -c '^[<>]' || true)"
[ "$differing" -gt 40 ] || fail "mutation did not land: only $differing differing line(s), too few to close the pipe"
printf 'stale-on-purpose\n' > "$STAMP"

# `$?` after `if ! cmd` is the NEGATION's status, not the command's, so the
# status is captured before it is tested -- otherwise this reports "exit 0" for
# the very SIGPIPE it exists to name.
red_code=0
bash scripts/ensure_generated.sh >"$WORK/red.log" 2>&1 || red_code=$?
if [ "$red_code" -ne 0 ]; then
  cat "$WORK/red.log" >&2
  if [ "$red_code" -eq 141 ]; then
    fail "the script died of SIGPIPE printing its own staleness diff ($differing differing lines) instead of regenerating"
  fi
  fail "the script failed (exit $red_code) on a long staleness diff instead of regenerating"
fi
grep -q '\[ensure-generated\] ok' "$WORK/red.log" \
  || { cat "$WORK/red.log" >&2; fail "the script exited 0 without reporting a completed regeneration"; }

echo "ensure-generated-selftest: ok ($differing differing lines regenerated cleanly)"
