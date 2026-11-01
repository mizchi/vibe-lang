#!/usr/bin/env bash
# The runner scripts/vibe_run.sh hands to `runtime/vibe run` (#3674).
#
# vibe_run.sh selects its tools through the launcher's own variables:
# VIBE_CLI_WASM is the seed and VIBE_RUNNER is this file. The launcher runs the
# compiled program with its environment, so without this file the program
# would inherit both, and a tool that runs `runtime/vibe` itself
# (scripts/review_lint.vibex's `vibe grep`) would get the seed as its
# compiler without anyone having chosen it. lint_review_regressions.sh
# exports a stage2 for exactly that call.
#
# So the compiler runs with the environment as is, and the program runs with
# the caller's VIBE_CLI_WASM and VIBE_RUNNER put back (VIBE_RUN_CALLER_*,
# recorded by vibe_run.sh as `set:<value>` or `unset`). Both run on the node
# runner (scripts/viberun_node.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# First non-flag argument is the wasm module, as in viberun_node.sh.
module=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) module="$arg"; break ;;
  esac
done

if [ -z "${VIBE_CLI_WASM:-}" ] || [ "$module" != "$VIBE_CLI_WASM" ]; then
  restore() { # <var> <recorded>
    case "$2" in
      set:*) export "$1=${2#set:}" ;;
      unset) unset "$1" ;;
      *) echo "vibe_run_runner.sh: $1 was not recorded by vibe_run.sh" >&2; exit 2 ;;
    esac
  }
  restore VIBE_CLI_WASM "${VIBE_RUN_CALLER_CLI_WASM:-}"
  restore VIBE_RUNNER "${VIBE_RUN_CALLER_RUNNER:-}"
  unset VIBE_RUN_CALLER_CLI_WASM VIBE_RUN_CALLER_RUNNER
fi
exec bash "$SCRIPT_DIR/viberun_node.sh" "$@"
