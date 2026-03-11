#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_SCRIPT="$SCRIPT_DIR/generate_selfhost_bundle.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_bundle_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/vibe/compiler"

cat > "$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" <<'EOF'
# group	path
core	polyfill.vibe
syntax	token.vibe
entry	index.vibe
EOF

cat > "$TMP_ROOT/vibe/compiler/polyfill.vibe" <<'EOF'
let polyfill = 1
EOF

cat > "$TMP_ROOT/vibe/compiler/token.vibe" <<'EOF'
let token = polyfill
EOF

cat > "$TMP_ROOT/vibe/compiler/index.vibe" <<'EOF'
let index = token
EOF

VIBE_SELFHOST_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SELFHOST_SOURCE_MANIFEST="$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" \
VIBE_SELFHOST_BUNDLE_OUT="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe" \
bash "$BUNDLE_SCRIPT" >/dev/null

OUT="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe"
if [ ! -f "$OUT" ]; then
  echo "generate-selfhost-bundle self-test: expected bundle output" >&2
  exit 1
fi

for path in polyfill token index; do
  if ! rg -q "\"vibe/compiler/${path}\\.vibe\"" "$OUT"; then
    echo "generate-selfhost-bundle self-test: missing ${path}.vibe entry" >&2
    cat "$OUT" >&2
    exit 1
  fi
done

polyfill_line="$(rg -n '"vibe/compiler/polyfill\.vibe"' "$OUT" | cut -d: -f1)"
token_line="$(rg -n '"vibe/compiler/token\.vibe"' "$OUT" | cut -d: -f1)"
index_line="$(rg -n '"vibe/compiler/index\.vibe"' "$OUT" | cut -d: -f1)"

if [ "$polyfill_line" -ge "$token_line" ] || [ "$token_line" -ge "$index_line" ]; then
  echo "generate-selfhost-bundle self-test: manifest order was not preserved" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! rg -q 'export let selfhost_source_groups' "$OUT"; then
  echo "generate-selfhost-bundle self-test: missing selfhost_source_groups export" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! rg -Fq 'push_grouped_source_pair(groups, "core", source_0)' "$OUT"; then
  echo "generate-selfhost-bundle self-test: missing core group mapping" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! rg -Fq 'push_grouped_source_pair(groups, "syntax", source_1)' "$OUT"; then
  echo "generate-selfhost-bundle self-test: missing syntax group mapping" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! rg -Fq 'push_grouped_source_pair(groups, "entry", source_2)' "$OUT"; then
  echo "generate-selfhost-bundle self-test: missing entry group mapping" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "generate-selfhost-bundle self-test: ok"
