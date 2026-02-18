#!/bin/bash
# Run `vibe normalize --write` on all .vibe source files.
# Files are processed per-directory to keep each invocation fast.
# Usage:
#   scripts/vibe_normalize_all.sh                     — normalize --write (fix mode)
#   scripts/vibe_normalize_all.sh --check             — verify already normalized (CI mode)
#   scripts/vibe_normalize_all.sh --skip-cached       — skip files whose hash matches cache
#   scripts/vibe_normalize_all.sh --check --skip-cached — check mode with cache
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

MODE="fix"
USE_CACHE=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --skip-cached) USE_CACHE=1 ;;
  esac
done

CACHE_FILE="_build/.normalize-cache"

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

# Check cache for a file. Returns 0 (true) if hash matches cache.
cache_hit() {
  local file="$1"
  if [ "$USE_CACHE" != "1" ] || [ ! -f "$CACHE_FILE" ]; then
    return 1
  fi
  local current_hash
  current_hash=$(shasum "$file" | cut -d' ' -f1)
  grep -q "^${current_hash}	${file}$" "$CACHE_FILE" 2>/dev/null
}

# Collect unique directories containing .vibe files (excluding known problematic dirs)
DIRS=()
for root in "${SOURCE_ROOTS[@]}"; do
  while IFS= read -r d; do
    DIRS+=("$d")
  done < <(find "$root" -name '*.vibe' -type f -exec dirname {} \; | sort -u | grep -Ev "^($EXCLUDE_DIRS)$")
done

TOTAL=0
SKIPPED=0
for dir in "${DIRS[@]}"; do
  FILES=()
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(find "$dir" -maxdepth 1 -name '*.vibe' -type f | sort)
  [ ${#FILES[@]} -eq 0 ] && continue

  if [ "$USE_CACHE" = "1" ]; then
    CHANGED_FILES=()
    for f in "${FILES[@]}"; do
      if cache_hit "$f"; then
        SKIPPED=$((SKIPPED + 1))
      else
        CHANGED_FILES+=("$f")
      fi
    done
    TOTAL=$((TOTAL + ${#FILES[@]}))
    if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
      "$VIBE_BIN" normalize --write "${CHANGED_FILES[@]}"
    fi
  else
    TOTAL=$((TOTAL + ${#FILES[@]}))
    "$VIBE_BIN" normalize --write "${FILES[@]}"
  fi
done

# Update cache after normalize (always, so cache reflects post-normalize state)
if [ "$USE_CACHE" = "1" ]; then
  mkdir -p "$(dirname "$CACHE_FILE")"
  : > "$CACHE_FILE"
  for root in "${SOURCE_ROOTS[@]}"; do
    while IFS= read -r f; do
      hash=$(shasum "$f" | cut -d' ' -f1)
      printf '%s\t%s\n' "$hash" "$f" >> "$CACHE_FILE"
    done < <(find "$root" -name '*.vibe' -type f | grep -Ev "^($EXCLUDE_DIRS)/" | sort)
  done
fi

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
  if [ "$USE_CACHE" = "1" ]; then
    echo "normalize: $TOTAL files OK ($SKIPPED cached, $((TOTAL - SKIPPED)) checked)"
  else
    echo "normalize: $TOTAL files OK (all already normalized)"
  fi
else
  if [ "$USE_CACHE" = "1" ]; then
    echo "normalize: $TOTAL files ($SKIPPED cached, $((TOTAL - SKIPPED)) written)"
  else
    echo "normalize: $TOTAL files written"
  fi
fi
