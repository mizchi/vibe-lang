#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATE_SCRIPT="$SCRIPT_DIR/generate_selfhost_bundle.sh"
CHECK_SCRIPT="$SCRIPT_DIR/check_selfhost_bundle_sync.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_bundle_sync_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/vibe/compiler"

cat > "$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" <<'EOF'
# group	path
core	polyfill.vibe
entry	index.vibe
EOF

cat > "$TMP_ROOT/vibe/compiler/polyfill.vibe" <<'EOF'
let polyfill = 1
EOF

cat > "$TMP_ROOT/vibe/compiler/index.vibe" <<'EOF'
let index = polyfill
EOF

VIBE_SELFHOST_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SELFHOST_SOURCE_MANIFEST="$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" \
VIBE_SELFHOST_BUNDLE_OUT="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe" \
bash "$GENERATE_SCRIPT" >/dev/null

VIBE_SELFHOST_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SELFHOST_SOURCE_MANIFEST="$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" \
VIBE_SELFHOST_BUNDLE_EXPECTED="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe" \
bash "$CHECK_SCRIPT" >/dev/null

cat > "$TMP_ROOT/vibe/compiler/index.vibe" <<'EOF'
let index = polyfill + 1
EOF

if VIBE_SELFHOST_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_SELFHOST_SOURCE_MANIFEST="$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" \
  VIBE_SELFHOST_BUNDLE_EXPECTED="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe" \
  bash "$CHECK_SCRIPT" >/dev/null 2>&1; then
  echo "check-selfhost-bundle-sync self-test: expected drift detection failure" >&2
  exit 1
fi

echo "check-selfhost-bundle-sync self-test: ok"
