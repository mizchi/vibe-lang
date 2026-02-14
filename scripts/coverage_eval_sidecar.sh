#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
  cat <<'EOF' >&2
usage: coverage_eval_sidecar.sh <db-path> <target>

example:
  scripts/coverage_eval_sidecar.sh ./tmp1.db validate

env:
  VIBE_EVAL_COVERAGE_DIR=<dir>  # default: _build/coverage/eval-sidecar
  VIBE_WASM_SOURCE_COVERAGE_MODE=wasm|wasm-js-string
  VIBE_WASM_SOURCE_COVERAGE_NO_DCE=0|1
  VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP=0|1
EOF
}

sanitize_target() {
  local raw="$1"
  local out=""
  local i ch
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    case "$ch" in
      [a-zA-Z0-9_-]) out+="$ch" ;;
      *) out+="_" ;;
    esac
  done
  if [ -z "$out" ]; then
    out="unnamed"
  fi
  printf '%s' "$out"
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

DB_PATH="$1"
TARGET="$2"

if [ ! -f "$DB_PATH" ]; then
  echo "[eval sidecar coverage] db not found: $DB_PATH" >&2
  exit 1
fi

if [[ "$DB_PATH" == *.db && "${#DB_PATH}" -gt 3 ]]; then
  TESTS_DIR="${DB_PATH%.db}.tests"
else
  TESTS_DIR="${DB_PATH}.tests"
fi

SAFE_TARGET="$(sanitize_target "$TARGET")"
TEST_PATH="$TESTS_DIR/${SAFE_TARGET}_test.vibe"

if [ ! -f "$TEST_PATH" ]; then
  echo "[eval sidecar coverage] sidecar test not found: $TEST_PATH" >&2
  exit 1
fi

OUT_DIR="${VIBE_EVAL_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/eval-sidecar}"
mkdir -p "$OUT_DIR"

db_norm="${DB_PATH#./}"
if [[ "$db_norm" == "$PROJECT_ROOT/"* ]]; then
  db_norm="${db_norm#$PROJECT_ROOT/}"
fi
db_slug="${db_norm//\//__}"
entry_path="$OUT_DIR/${db_slug}__${SAFE_TARGET}.vibe"

cat "$DB_PATH" >"$entry_path"
if [ -s "$entry_path" ]; then
  printf '\n' >>"$entry_path"
fi
cat "$TEST_PATH" >>"$entry_path"

echo "[eval sidecar coverage] db=$DB_PATH target=$TARGET"
echo "[eval sidecar coverage] sidecar=$TEST_PATH"
echo "[eval sidecar coverage] entry=$entry_path"

VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 \
  "$SCRIPT_DIR/coverage_wasm_source.sh" "$entry_path"
