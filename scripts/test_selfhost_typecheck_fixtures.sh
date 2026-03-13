#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_typecheck_fixture_parity}"
CASES_FILE="$OUT_DIR/cases.txt"
ALLOWLIST_FILE="${VIBE_SELFHOST_TYPECHECK_FIXTURE_ALLOWLIST_FILE:-$PROJECT_ROOT/bench/selfhost_check_parity/typecheck_allowed_diff_patterns.txt}"
SNAPSHOT_FILE="${VIBE_SELFHOST_TYPECHECK_FIXTURE_SNAPSHOT_FILE:-$PROJECT_ROOT/bench/golden/selfhost_typecheck_fixture_parity_snapshot.json}"

mkdir -p "$OUT_DIR"
: > "$CASES_FILE"

find "$PROJECT_ROOT/fixtures/typecheck" -maxdepth 1 -type f -name '*.vibe' | sort | while read -r path; do
  rel="${path#$PROJECT_ROOT/}"
  printf '%s\n' "$rel" >> "$CASES_FILE"
done

if [ ! -f "$ALLOWLIST_FILE" ]; then
  mkdir -p "$(dirname "$ALLOWLIST_FILE")"
  : > "$ALLOWLIST_FILE"
fi

OUT_DIR="$OUT_DIR" \
VIBE_CHECK_PARITY_CASES_FILE="$CASES_FILE" \
VIBE_CHECK_PARITY_ALLOWLIST_FILE="$ALLOWLIST_FILE" \
VIBE_CHECK_PARITY_SNAPSHOT_FILE="$SNAPSHOT_FILE" \
"$SCRIPT_DIR/test_selfhost_check_parity.sh"
