#!/usr/bin/env bash
# Run only the tests the change can actually reach (#988).
#
#   bash scripts/test_affected.sh [--changed-from <ref>] [--changed <path>]...
#                                 [--dry-run] [--explain] [--jobs N]
#
# Selection comes from scripts/affected_tests.mjs, which walks the compiler's
# OWN resolved import graph (`vibe deps --direct`, backed by the incremental
# build's persistent header cache) upward from the changed files. Execution is
# the ordinary scripts/unit_test_runner.sh, handed an explicit subset -- this
# script chooses WHAT to run and changes nothing about HOW tests run, so a
# selected test behaves exactly as it does in a full run.
#
# FAIL OPEN. The selector exits 2 when it cannot prove an answer (a change
# outside the vibe import graph, no stage2 for this checkout, an incomplete
# index). This script turns that into a FULL run, never into an empty one:
# "we could not tell" and "nothing is affected" must not produce the same
# green, or the suite quietly stops protecting anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

dry_run=0
sel_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --changed-from|--changed|--jobs) sel_args+=("$1" "${2:?$1 requires a value}"); shift 2 ;;
    --explain) sel_args+=("$1"); shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's|^# \{0,1\}||'
      exit 0 ;;
    *) echo "test_affected: unknown argument: $1" >&2; exit 2 ;;
  esac
done

selected="$(mktemp -t vibe-affected-XXXXXX)"
trap 'rm -f "$selected"' EXIT

set +e
node scripts/affected_tests.mjs "${sel_args[@]}" > "$selected"
sel_rc=$?
set -e

if [ "$sel_rc" = "2" ]; then
  echo "[test-affected] selection undetermined -> running the FULL battery"
  [ "$dry_run" = "1" ] && exit 0
  exec bash scripts/unit_test_runner.sh
fi
if [ "$sel_rc" != "0" ]; then
  echo "[test-affected] selector failed (exit $sel_rc)" >&2
  exit "$sel_rc"
fi

count="$(grep -cve '^[[:space:]]*$' "$selected" || true)"
total="$(bash scripts/unit_test_runner.sh --list | grep -cve '^[[:space:]]*\(#\|$\)' || true)"
if [ "$count" = "0" ]; then
  # A real answer, not a failure: nothing in the change is reachable from any
  # test entry. Said out loud so it is never mistaken for a suite that ran.
  echo "[test-affected] 0 of $total entries affected -- nothing to run"
  exit 0
fi
echo "[test-affected] $count of $total entries affected"
if [ "$dry_run" = "1" ]; then
  cat "$selected"
  exit 0
fi
VIBE_UNIT_TEST_ALLOWLIST="$selected" exec bash scripts/unit_test_runner.sh
