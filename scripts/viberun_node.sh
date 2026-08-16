#!/usr/bin/env bash
# A `viberun`-compatible runner backed by the node host runner (#1870).
#
# `runtime/vibe` executes wasm through `$VIBE_RUNNER`, which defaults to
# `bin/viberun` -- a Rust binary that embeds wasmtime and is built separately.
# A plain checkout does not have one, so every `vibe` subcommand that needs to
# run wasm dies with "runner not found or not executable". That included
# `vibe grep`, which is the backend of the review-regressions lint's AST tier:
# the tier silently skipped, the lint still printed "ok", and the #1809 drift
# rule it carries guarded nothing. See #1870.
#
# The repository already ships a runner that works anywhere node does
# (`scripts/run_wasm_vibe_host_runner.sh`), so this is the whole adapter:
#
#   VIBE_RUNNER=scripts/viberun_node.sh \
#   VIBE_CLI_WASM=<a stage2.wasm> \
#     runtime/vibe grep --pattern '...' lib
#
# `runtime/vibe` calls the runner in TWO shapes and they need different
# exports:
#
#   "$RUNNER" "$cli" "$src" "$out" "$entry"   -- drive the compiler: cli_main
#   "$RUNNER" "$out"                          -- run a compiled program: _start
#
# Invoking `cli_main` unconditionally makes the second shape fail with
# "missing export: cli_main" for every test/run/bench the program lane uses, so
# the export is chosen from whether the wasm being run IS the compiler.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# First non-flag argument is the wasm module (`--bench` and friends precede it).
module=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) module="$arg"; break ;;
  esac
done

is_cli=0
if [ -n "${VIBE_CLI_WASM:-}" ] && [ -n "$module" ] && [ "$module" = "$VIBE_CLI_WASM" ]; then
  is_cli=1
fi
case "$module" in
  */vibe-cli.wasm|*/stage0.wasm|*/stage1.wasm|*/stage2.wasm) is_cli=1 ;;
esac

if [ "$is_cli" -eq 1 ]; then
  exec bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$@"
fi
exec bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" "$@"
