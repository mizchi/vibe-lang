#!/usr/bin/env bash
# Standalone single-candidate oracle check, built on tests/fuzz/lib_oracle.sh.
#
#   bash tests/fuzz/classify.sh DIR [--cli path/to/stage2.wasm] [--mutate]
#
# DIR must contain single.vibe (and optionally main.vibe, to also exercise
# the FS-linked lane, expected.txt for the lane-independent oracle and
# skip_lanes). With --mutate, DIR/mut.vibe (else DIR/single.vibe) is judged
# the way run_fuzz.sh --mutate judges a mutated input: OK or COMPILE_DIAG is
# the expected rejection, DIAG_NO_LOCATION / DIAG_INTERNAL_TOKEN a malformed
# diagnostic, COMPILE_CRASH / COMPILE_HANG a compiler failure -- see
# lib_oracle.sh's classify_mutant. Prints "CLASS detail..." to stdout -- see
# tests/fuzz/lib_oracle.sh's classify() for the exact class vocabulary. This
# is the same oracle tests/fuzz/run_fuzz.sh uses per seed; tests/fuzz/reduce.py
# shells out to this script once per reduction candidate so both tools agree
# on what counts as a finding.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"

DIR="${1:?usage: tests/fuzz/classify.sh DIR [--cli path]}"
shift
CLI=""
MUTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cli) CLI="$2"; shift 2 ;;
    --mutate) MUTATE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# WHICH compiler answered (AGENTS.md, "Which compiler answered?"). This used
# to default to `ls -t .../stage2.wasm | head -1` -- newest by MTIME, a
# different question from "the compiler built from this checkout", answered
# wrong on a reused workspace and while a build is touching directories.
#
# It matters here as much as in run_fuzz.sh, because this is where a finding
# gets its NAME: tests/fuzz/reduce.py shells out once per reduction candidate,
# and `MISMATCH bump=... rc=...` is pasted into an issue with no stderr
# attached. A reducer silently running a different generation can also reduce
# a finding to nothing and have that read as "not reproducible".
#
# Measured before this change, with HEAD at 632bb067b and no generation for
# it: classify.sh answered from a `f5002ebd9` build without a word, while the
# strict resolver refused (#2959).
# shellcheck source=scripts/resolve_stage2.sh
. "$ROOT/scripts/resolve_stage2.sh"
CLI="$(resolve_stage2_strict classify "$CLI")" || exit 2

# shellcheck source=tests/fuzz/lib_oracle.sh
source "$ROOT/tests/fuzz/lib_oracle.sh"
if [ "$MUTATE" -eq 1 ]; then
  src="$DIR/mut.vibe"
  [ -f "$src" ] || src="$DIR/single.vibe"
  classify_mutant "$src" "$DIR/mut.wasm"
else
  classify "$DIR"
fi
