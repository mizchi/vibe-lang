#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${VIBE_CLI_BIN_OVERRIDE:-}" ]]; then
  exec "$VIBE_CLI_BIN_OVERRIDE" "$@"
fi

source "$ROOT_DIR/scripts/ensure_native_cli.sh"
exec "$VIBE_CLI_BIN" "$@"
