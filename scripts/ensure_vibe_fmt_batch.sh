#!/usr/bin/env bash
# Compile lib/@vibe/cli/fmt.vibe (the multi-file/sharded `vibe fmt` batch
# entry, #see lib/@vibe/cli/fmt.vibe header) to _build/vibe_fmt/fmt_batch.wasm
# if it's missing or stale. Mirrors scripts/ensure_vibe_fmt_entry.sh; kept
# separate because fmt.vibe pulls in @vibe/process (Process effect) which
# the single-file fmt_entry.vibe does not need.
#
# Staleness tracks the entry's RESOLVED import closure (captured into
# fmt_batch.wasm.deps by ensure_entry_wasm.sh), not a hand-maintained file
# list -- a hand list cannot see transitive dependencies (#2260).
#
# Prints the repo-root-relative path to the compiled wasm on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/scripts/ensure_entry_wasm.sh" \
  "lib/@vibe/cli/fmt.vibe" "_build/vibe_fmt/fmt_batch.wasm"
