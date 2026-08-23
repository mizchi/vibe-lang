#!/usr/bin/env bash
# Compile lib/@vibe/cli/fmt_entry.vibe (the `vibe fmt` entry point) to
# _build/vibe_fmt/fmt_entry.wasm if it's missing or stale. Shared by
# scripts/vibe_fmt.sh (single-file) and scripts/vibe_fmt_parallel.mjs
# (multi-worker bulk apply/check) so both compile the exact same way and
# reuse the exact same cached artifact.
#
# Staleness tracks the entry's RESOLVED import closure (captured into
# fmt_entry.wasm.deps by ensure_entry_wasm.sh), not a hand-maintained file
# list -- a hand list cannot see transitive dependencies (#2260).
#
# Prints the repo-root-relative path to the compiled wasm on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/scripts/ensure_entry_wasm.sh" \
  "lib/@vibe/cli/fmt_entry.vibe" "_build/vibe_fmt/fmt_entry.wasm"
