#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

find fixtures/warnings -maxdepth 1 -type f -name '*.vibe' | sort | while read -r path; do
  moon run src/cmd/warning_fixture/main.mbt --target native -- --path "$path"
done
