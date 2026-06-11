#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VIBE_CLI_RELEASE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"

env VIBE_TEST_BACKEND=compiled \
  "$VIBE_CLI_BIN" test "$PROJECT_ROOT/vibe/compiler/cli_adapter_cache_test.vibe"
