#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_SELFHOST_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
COMPILER_DIR="${VIBE_SELFHOST_COMPILER_DIR:-$PROJECT_ROOT/vibe/compiler}"
MANIFEST="${VIBE_SELFHOST_SOURCE_MANIFEST:-$COMPILER_DIR/selfhost_sources_manifest.tsv}"
EXPECTED="${VIBE_SELFHOST_BUNDLE_EXPECTED:-$COMPILER_DIR/selfhost_sources_bundle.vibe}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_bundle_sync.XXXXXX")"
TMP_OUT="$TMP_ROOT/selfhost_sources_bundle.vibe"
trap 'rm -rf "$TMP_ROOT"' EXIT

if [ ! -f "$EXPECTED" ]; then
  echo "selfhost bundle sync: expected bundle not found: $EXPECTED" >&2
  exit 1
fi

VIBE_SELFHOST_PROJECT_ROOT="$PROJECT_ROOT" \
VIBE_SELFHOST_COMPILER_DIR="$COMPILER_DIR" \
VIBE_SELFHOST_SOURCE_MANIFEST="$MANIFEST" \
VIBE_SELFHOST_BUNDLE_OUT="$TMP_OUT" \
bash "$SCRIPT_DIR/generate_selfhost_bundle.sh" >/dev/null

if ! cmp -s "$EXPECTED" "$TMP_OUT"; then
  echo "selfhost bundle sync: drift detected; regenerate $EXPECTED" >&2
  diff -u "$EXPECTED" "$TMP_OUT" >&2 || true
  exit 1
fi

echo "selfhost bundle sync: ok"
