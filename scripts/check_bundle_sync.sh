#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_SELFHOST_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
COMPILER_DIR="${VIBE_SELFHOST_COMPILER_DIR:-$PROJECT_ROOT/lib/@vibe/compiler}"
MANIFEST="${VIBE_SELFHOST_SOURCE_MANIFEST:-$COMPILER_DIR/sources_manifest.tsv}"
EXPECTED="${VIBE_SELFHOST_BUNDLE_EXPECTED:-$COMPILER_DIR/sources_bundle.vibe}"
EXPECTED_ADAPTER="${VIBE_SELFHOST_ADAPTER_BUNDLE_EXPECTED:-$COMPILER_DIR/cli_adapter_bundle.vibe}"
EXPECTED_RUNTIME_ENTRY="${VIBE_SELFHOST_RUNTIME_ENTRY_BUNDLE_EXPECTED:-$COMPILER_DIR/selfbuild_runtime_entry_bundle.vibe}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_bundle_sync.XXXXXX")"
TMP_OUT="$TMP_ROOT/sources_bundle.vibe"
TMP_OUT_ADAPTER="$TMP_ROOT/cli_adapter_bundle.vibe"
TMP_OUT_RUNTIME_ENTRY="$TMP_ROOT/selfbuild_runtime_entry_bundle.vibe"
trap 'rm -rf "$TMP_ROOT"' EXIT

ensure_expected_file() {
  local expected_path="$1"
  if [ ! -f "$expected_path" ]; then
    echo "selfhost bundle sync: expected bundle not found: $expected_path" >&2
    exit 1
  fi
}

check_generated_bundle() {
  local expected_path="$1"
  local generated_path="$2"
  if cmp -s "$expected_path" "$generated_path"; then
    return 0
  fi
  echo "selfhost bundle sync: drift detected; regenerate $expected_path" >&2
  diff -u "$expected_path" "$generated_path" >&2 || true
  return 1
}

ensure_expected_file "$EXPECTED"
ensure_expected_file "$EXPECTED_ADAPTER"
ensure_expected_file "$EXPECTED_RUNTIME_ENTRY"

VIBE_SELFHOST_PROJECT_ROOT="$PROJECT_ROOT" \
VIBE_SELFHOST_COMPILER_DIR="$COMPILER_DIR" \
VIBE_SELFHOST_SOURCE_MANIFEST="$MANIFEST" \
VIBE_SELFHOST_BUNDLE_OUT="$TMP_OUT" \
VIBE_SELFHOST_ADAPTER_BUNDLE_OUT="$TMP_OUT_ADAPTER" \
VIBE_SELFHOST_RUNTIME_ENTRY_BUNDLE_OUT="$TMP_OUT_RUNTIME_ENTRY" \
bash "$SCRIPT_DIR/generate_bundle.sh" >/dev/null

status=0
check_generated_bundle "$EXPECTED_ADAPTER" "$TMP_OUT_ADAPTER" || status=1
check_generated_bundle "$EXPECTED_RUNTIME_ENTRY" "$TMP_OUT_RUNTIME_ENTRY" || status=1
check_generated_bundle "$EXPECTED" "$TMP_OUT" || status=1
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "selfhost bundle sync: ok"
