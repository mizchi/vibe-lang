#!/bin/bash
# Run `vibe normalize --write` on all .vibe source files.
# Files are processed per-directory to keep each invocation fast.
# Usage:
#   scripts/vibe_normalize_all.sh           — normalize --write (fix mode)
#   scripts/vibe_normalize_all.sh --check   — verify already normalized (CI mode)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

MODE="fix"
if [ "${1:-}" = "--check" ]; then
  MODE="check"
fi

# Build vibe CLI (reuse if already built)
VIBE_BIN="_build/native/debug/build/cmd/vibe/vibe.exe"
if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native src/cmd/vibe --warn-list '-29'
fi

# Source roots (bench excluded: cross-root imports)
SOURCE_ROOTS=(examples vibe)

# Directories to exclude from normalize
# - examples/wasm: cross-root imports (../../vibe/std/wasm/...) not supported
EXCLUDE_DIRS="examples/wasm"

# Collect unique directories containing .vibe files (excluding known problematic dirs)
DIRS=()
for root in "${SOURCE_ROOTS[@]}"; do
  while IFS= read -r d; do
    DIRS+=("$d")
  done < <(find "$root" -name '*.vibe' -type f -exec dirname {} \; | sort -u | grep -Ev "^($EXCLUDE_DIRS)$")
done

TOTAL=0
for dir in "${DIRS[@]}"; do
  FILES=()
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(find "$dir" -maxdepth 1 -name '*.vibe' -type f | sort)
  [ ${#FILES[@]} -eq 0 ] && continue
  TOTAL=$((TOTAL + ${#FILES[@]}))
  "$VIBE_BIN" normalize --write "${FILES[@]}"
done

ALL_VIBE=()
for root in "${SOURCE_ROOTS[@]}"; do
  while IFS= read -r f; do
    ALL_VIBE+=("$f")
  done < <(find "$root" -name '*.vibe' -type f | grep -Ev "^($EXCLUDE_DIRS)/")
done

if [ "$MODE" = "check" ]; then
  CHANGED=$(git diff --name-only -- "${ALL_VIBE[@]}" || true)
  if [ -n "$CHANGED" ]; then
    echo "ERROR: The following files are not normalized:" >&2
    echo "$CHANGED" >&2
    echo "" >&2
    echo "Run 'just vibe-normalize' to fix." >&2
    git checkout -- "${ALL_VIBE[@]}"
    exit 1
  fi
  echo "normalize: $TOTAL files OK (all already normalized)"
else
  echo "normalize: $TOTAL files written"
fi
