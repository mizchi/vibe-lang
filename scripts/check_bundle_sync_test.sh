#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATE_SCRIPT="$SCRIPT_DIR/generate_bundle.sh"
CHECK_SCRIPT="$SCRIPT_DIR/check_bundle_sync.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_bundle_sync_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/lib/@vibe/compiler"

cat > "$TMP_ROOT/lib/@vibe/compiler/sources_manifest.tsv" <<'EOF'
# group	path
core	polyfill.vibe
entry	cli_adapter.vibe
entry	index.vibe
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/polyfill.vibe" <<'EOF'
let polyfill = 1
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/cli_adapter.vibe" <<'EOF'
let cli_main = polyfill
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/index.vibe" <<'EOF'
let index = polyfill
EOF

VIBE_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SOURCE_MANIFEST="$TMP_ROOT/lib/@vibe/compiler/sources_manifest.tsv" \
VIBE_BUNDLE_OUT="$TMP_ROOT/lib/@vibe/compiler/sources_bundle.vibe" \
bash "$GENERATE_SCRIPT" >/dev/null

VIBE_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SOURCE_MANIFEST="$TMP_ROOT/lib/@vibe/compiler/sources_manifest.tsv" \
VIBE_BUNDLE_EXPECTED="$TMP_ROOT/lib/@vibe/compiler/sources_bundle.vibe" \
bash "$CHECK_SCRIPT" >/dev/null

cat > "$TMP_ROOT/lib/@vibe/compiler/index.vibe" <<'EOF'
let index = polyfill + 1
EOF

if VIBE_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_SOURCE_MANIFEST="$TMP_ROOT/lib/@vibe/compiler/sources_manifest.tsv" \
  VIBE_BUNDLE_EXPECTED="$TMP_ROOT/lib/@vibe/compiler/sources_bundle.vibe" \
  bash "$CHECK_SCRIPT" >"$TMP_ROOT/main.stdout" 2>"$TMP_ROOT/main.stderr"; then
  echo "check-bundle-sync self-test: expected drift detection failure" >&2
  exit 1
fi
if ! grep -Fq "$TMP_ROOT/lib/@vibe/compiler/sources_bundle.vibe" "$TMP_ROOT/main.stderr"; then
  echo "check-bundle-sync self-test: expected main bundle drift path" >&2
  exit 1
fi

cat > "$TMP_ROOT/lib/@vibe/compiler/index.vibe" <<'EOF'
let index = polyfill
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/cli_adapter.vibe" <<'EOF'
let cli_main = polyfill + 1
EOF

if VIBE_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_SOURCE_MANIFEST="$TMP_ROOT/lib/@vibe/compiler/sources_manifest.tsv" \
  VIBE_BUNDLE_EXPECTED="$TMP_ROOT/lib/@vibe/compiler/sources_bundle.vibe" \
  bash "$CHECK_SCRIPT" >"$TMP_ROOT/adapter.stdout" 2>"$TMP_ROOT/adapter.stderr"; then
  echo "check-bundle-sync self-test: expected adapter drift detection failure" >&2
  exit 1
fi
if ! grep -Fq "$TMP_ROOT/lib/@vibe/compiler/cli_adapter_bundle.vibe" "$TMP_ROOT/adapter.stderr"; then
  echo "check-bundle-sync self-test: expected adapter bundle drift path" >&2
  exit 1
fi

echo "check-bundle-sync self-test: ok"
