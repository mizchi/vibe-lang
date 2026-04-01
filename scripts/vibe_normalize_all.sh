#!/bin/bash
# Run `vibe normalize` on all .vibe source files.
# Files are processed per-directory to keep each invocation fast.
# Usage:
#   scripts/vibe_normalize_all.sh                              — normalize --write (fix mode)
#   scripts/vibe_normalize_all.sh --check                      — verify already normalized (CI mode)
#   scripts/vibe_normalize_all.sh --skip-cached                — skip files whose hash matches cache
#   scripts/vibe_normalize_all.sh --check --skip-cached        — check mode with cache
#   scripts/vibe_normalize_all.sh --check examples vibe        — check explicit roots
# env:
#   VIBE_NORMALIZE_SOURCE_ROOTS="examples vibe"                — default roots when no positional roots are given
#   VIBE_NORMALIZE_EXCLUDE_DIRS="examples/wasm"                — space/comma separated exclude dirs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"

MODE="fix"
USE_CACHE=0
CLI_SOURCE_ROOTS=()
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --skip-cached) USE_CACHE=1 ;;
    *) CLI_SOURCE_ROOTS+=("$arg") ;;
  esac
done

CACHE_FILE="_build/.normalize-cache"
NORMALIZE_BATCH_SIZE="${VIBE_NORMALIZE_BATCH_SIZE:-1}"
if ! [[ "$NORMALIZE_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: VIBE_NORMALIZE_BATCH_SIZE must be a positive integer." >&2
  exit 2
fi

# Build vibe CLI (reuse if already built)
VIBE_BIN="${VIBE_NORMALIZE_BIN:-$VIBE_CLI_BIN}"

# Source roots (bench excluded: cross-root imports)
# vibe/ excluded: normalize rewrites fn signatures to separated-annotation
# style which the compiler cannot yet parse back (see #109)
if [ ${#CLI_SOURCE_ROOTS[@]} -gt 0 ]; then
  SOURCE_ROOTS=("${CLI_SOURCE_ROOTS[@]}")
else
  SOURCE_ROOTS_RAW="${VIBE_NORMALIZE_SOURCE_ROOTS:-examples}"
  SOURCE_ROOTS_RAW="${SOURCE_ROOTS_RAW//,/ }"
  # shellcheck disable=SC2206
  SOURCE_ROOTS=($SOURCE_ROOTS_RAW)
fi

if [ ${#SOURCE_ROOTS[@]} -eq 0 ]; then
  echo "ERROR: no source roots provided." >&2
  exit 2
fi

for root in "${SOURCE_ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    echo "ERROR: source root does not exist: $root" >&2
    exit 2
  fi
done

# Directories to exclude from normalize
# - examples/wasm: external runtime fixtures are maintained manually
# - examples: normalize rewrites fn signatures to separated-annotation
#   style which the compiler cannot yet parse back (see #109)
EXCLUDE_DIRS_RAW="${VIBE_NORMALIZE_EXCLUDE_DIRS:-examples/wasm examples}"
EXCLUDE_DIRS_RAW="${EXCLUDE_DIRS_RAW//,/ }"
EXCLUDE_DIRS_REGEX="$(echo "$EXCLUDE_DIRS_RAW" | awk '{$1=$1; print}' | tr ' ' '|')"

# Explicit files to exclude from normalize
# - vibe/compiler/coverage_selfhost_suite_lib.vibe currently crashes native normalize
# - selfhost *_bundle.vibe files are generated artifacts; check-selfhost-bundle-sync
#   compares them against the generator output and normalize would cause false drift
EXCLUDE_FILES_RAW="${VIBE_NORMALIZE_EXCLUDE_FILES:-vibe/compiler/coverage_selfhost_suite_lib.vibe vibe/compiler/selfhost_sources_bundle.vibe vibe/compiler/selfhost_cli_adapter_bundle.vibe vibe/compiler/selfbuild_runtime_entry_bundle.vibe vibe/builtins/declarations.vibe}"
EXCLUDE_FILES_RAW="${EXCLUDE_FILES_RAW//,/ }"
EXCLUDE_FILES_REGEX="$(echo "$EXCLUDE_FILES_RAW" | awk '{$1=$1; print}' | tr ' ' '|')"

filter_excluded_dirs() {
  if [ -n "$EXCLUDE_DIRS_REGEX" ]; then
    grep -Ev "^($EXCLUDE_DIRS_REGEX)$" || true
  else
    cat
  fi
}

filter_excluded_files() {
  if [ -n "$EXCLUDE_DIRS_REGEX" ]; then
    grep -Ev "^($EXCLUDE_DIRS_REGEX)/" || true
  else
    cat
  fi
}

filter_excluded_explicit_files() {
  if [ -n "$EXCLUDE_FILES_REGEX" ]; then
    grep -Ev "^($EXCLUDE_FILES_REGEX)$" || true
  else
    cat
  fi
}

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

run_normalize_files() {
  local files=("$@")
  local offset=0
  while [ $offset -lt ${#files[@]} ]; do
    local batch=("${files[@]:$offset:$NORMALIZE_BATCH_SIZE}")
    if [ "$MODE" = "check" ]; then
      "$VIBE_BIN" normalize --check "${batch[@]}"
    else
      "$VIBE_BIN" normalize --write "${batch[@]}"
    fi
    offset=$((offset + NORMALIZE_BATCH_SIZE))
  done
}

# Collect unique directories containing .vibe files (excluding known problematic dirs)
DIRS=()
for root in "${SOURCE_ROOTS[@]}"; do
  while IFS= read -r d; do
    DIRS+=("$d")
  done < <(
    find "$root" \
      -name '*.vibe' \
      -type f \
      -not -name '.tmp_*' \
      -not -name '.vibe_test_case_*' \
      -not -name '.vibe_test_wasm_*' \
      -not -name '.vibe_compiled_repl_*' \
      -exec dirname {} \; |
      sort -u |
      filter_excluded_dirs
  )
done

TOTAL=0
SKIPPED=0
for dir in "${DIRS[@]}"; do
  FILES=()
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(
    find "$dir" -maxdepth 1 \
      -name '*.vibe' \
      -not -name 'index.vibe' \
      -not -name '.tmp_*' \
      -not -name '.vibe_test_case_*' \
      -not -name '.vibe_test_wasm_*' \
      -not -name '.vibe_compiled_repl_*' \
      -type f |
      sort |
      filter_excluded_explicit_files
  )
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
      run_normalize_files "${CHANGED_FILES[@]}"
    fi
  else
    TOTAL=$((TOTAL + ${#FILES[@]}))
    run_normalize_files "${FILES[@]}"
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
    done < <(
      find "$root" \
        -name '*.vibe' \
        -type f \
        -not -name '.tmp_*' \
        -not -name '.vibe_test_wasm_*' |
        filter_excluded_files |
        filter_excluded_explicit_files |
        sort
    )
  done
fi

if [ "$MODE" = "check" ]; then
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
