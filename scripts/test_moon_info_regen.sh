#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
warn_list="${VIBE_MOON_WARN_LIST:--1-6-7-9-24-29}"

HASH_BEFORE="$(mktemp "${TMPDIR:-/tmp}/vibe_moon_info_before.XXXXXX")"
HASH_AFTER="$(mktemp "${TMPDIR:-/tmp}/vibe_moon_info_after.XXXXXX")"
DIFF_OUT="$(mktemp "${TMPDIR:-/tmp}/vibe_moon_info_diff.XXXXXX")"
trap 'rm -f "$HASH_BEFORE" "$HASH_AFTER" "$DIFF_OUT"' EXIT

snapshot_mbti_hashes() {
  while IFS= read -r file; do
    if [ -f "$file" ]; then
      shasum "$file"
    fi
  done < <(git ls-files '*.mbti' | LC_ALL=C sort)
}

echo "[moon-info] first pass"
moon info
snapshot_mbti_hashes > "$HASH_BEFORE"

echo "[moon-info] second pass (idempotency)"
moon info
snapshot_mbti_hashes > "$HASH_AFTER"

if ! diff -u "$HASH_BEFORE" "$HASH_AFTER" > "$DIFF_OUT"; then
  echo "moon-info-regen: mbti hashes changed between consecutive moon info runs" >&2
  cat "$DIFF_OUT" >&2
  exit 1
fi

echo "[moon-info] check --deny-warn"
moon check --deny-warn --warn-list "$warn_list" --target js

echo "moon-info-regen: ok"
