#!/usr/bin/env bash
set -euo pipefail

if ! command -v flaker >/dev/null 2>&1; then
  echo "flaker_run: flaker command not found" >&2
  exit 127
fi

FLAKER_BIN="$(command -v flaker)"
FLAKER_REAL="$(realpath "$FLAKER_BIN")"

exec node "$FLAKER_REAL" run "$@"
