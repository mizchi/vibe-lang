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
# (`scripts/run_wasm_vibe_host_runner.sh`), and `viberun`'s calling convention
# for the CLI is just `<wasm> <args...>` against the `cli_main` export. So this
# is the whole adapter:
#
#   VIBE_RUNNER=scripts/viberun_node.sh \
#   VIBE_CLI_WASM=<a stage2.wasm> \
#     runtime/vibe grep --pattern '...' lib
#
# Scope note: this covers the `cli_main` ABI, which is what the query
# subcommands (grep / check / symbols / type-at / ...) use. A subcommand that
# invokes a different export needs its own handling; none of the lint's does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$@"
