#!/usr/bin/env bash
# Repository adapter for `vibe normalize` (#3674). The CLI owns arguments,
# diagnostics, --stdout/--check/write behavior and normalization. A checkout
# supplies the pinned seed and node runner instead of an installed toolchain.
# Paths resolve against the repository, as in the other repository adapters.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash "$ROOT_DIR/scripts/ensure_seed.sh" >&2
exec env \
  VIBE_CLI_WASM="$ROOT_DIR/bootstrap/seed/compiler.wasm" \
  VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" \
  "$ROOT_DIR/runtime/vibe" normalize "$@"
