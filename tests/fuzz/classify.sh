#!/usr/bin/env bash
# Standalone single-candidate oracle check, built on tests/fuzz/lib_oracle.sh.
#
#   bash tests/fuzz/classify.sh DIR [--cli path/to/stage2.wasm]
#
# DIR must contain single.vibe (and optionally main.vibe, to also exercise
# the FS-linked lane). Prints "CLASS detail..." to stdout -- see
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
while [ $# -gt 0 ]; do
  case "$1" in
    --cli) CLI="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$CLI" ]; then
  CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1)"
fi
if [ -z "$CLI" ] || [ ! -f "$CLI" ]; then
  echo "[classify] no stage2 CLI found; build one first (scripts/generations.sh build)" >&2
  exit 2
fi

# shellcheck source=tests/fuzz/lib_oracle.sh
source "$ROOT/tests/fuzz/lib_oracle.sh"
classify "$DIR"
