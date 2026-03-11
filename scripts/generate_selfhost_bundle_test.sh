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
entry	selfhost_cli_adapter.vibe
entry	selfhost_cli_adapter_bundle.vibe
EOF

cat > "$TMP_ROOT/vibe/compiler/polyfill.vibe" <<'EOF'
let polyfill = 1
EOF

cat > "$TMP_ROOT/vibe/compiler/token.vibe" <<'EOF'
let token = polyfill
EOF

cat > "$TMP_ROOT/vibe/compiler/index.vibe" <<'EOF'
import ./selfhost_cli_adapter_bundle.vibe { selfhost_cli_adapter_merged_source }

let index = String::length(selfhost_cli_adapter_merged_source()) + token
EOF

cat > "$TMP_ROOT/vibe/compiler/selfhost_cli_adapter.vibe" <<'EOF'
import ./token.vibe { token }

let cli_main = () -> Int { token }
EOF

VIBE_SELFHOST_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SELFHOST_SOURCE_MANIFEST="$TMP_ROOT/vibe/compiler/selfhost_sources_manifest.tsv" \
VIBE_SELFHOST_BUNDLE_OUT="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe" \
VIBE_SELFHOST_ADAPTER_BUNDLE_OUT="$TMP_ROOT/vibe/compiler/selfhost_cli_adapter_bundle.vibe" \
bash "$BUNDLE_SCRIPT" >/dev/null

OUT="$TMP_ROOT/vibe/compiler/selfhost_sources_bundle.vibe"
OUT_ADAPTER="$TMP_ROOT/vibe/compiler/selfhost_cli_adapter_bundle.vibe"
if [ ! -f "$OUT" ]; then
  echo "generate-selfhost-bundle self-test: expected bundle output" >&2
  exit 1
fi

if [ ! -f "$OUT_ADAPTER" ]; then
  echo "generate-selfhost-bundle self-test: expected adapter bundle output" >&2
  exit 1
fi

for path in polyfill token index selfhost_cli_adapter_bundle; do
  if ! rg -q "\"vibe/compiler/${path}\\.vibe\"" "$OUT"; then
    echo "generate-selfhost-bundle self-test: missing ${path}.vibe entry" >&2
    cat "$OUT" >&2
    exit 1
  fi
done

polyfill_line="$(rg -n '"vibe/compiler/polyfill\.vibe"' "$OUT" | cut -d: -f1)"
token_line="$(rg -n '"vibe/compiler/token\.vibe"' "$OUT" | cut -d: -f1)"
index_line="$(rg -n '"vibe/compiler/index\.vibe"' "$OUT" | cut -d: -f1)"
adapter_bundle_line="$(rg -n '"vibe/compiler/selfhost_cli_adapter_bundle\.vibe"' "$OUT" | cut -d: -f1)"

if [ "$polyfill_line" -ge "$token_line" ] || [ "$token_line" -ge "$index_line" ] || [ "$index_line" -ge "$adapter_bundle_line" ]; then
  echo "generate-selfhost-bundle self-test: manifest order was not preserved" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! rg -q 'export let selfhost_source_groups' "$OUT"; then
  echo "generate-selfhost-bundle self-test: missing selfhost_source_groups export" >&2
  cat "$OUT" >&2
  exit 1
fi

if rg -q '^export let selfhost_cli_adapter_sources' "$OUT"; then
  echo "generate-selfhost-bundle self-test: main bundle unexpectedly exports adapter closure" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! rg -q '^export let selfhost_cli_adapter_sources' "$OUT_ADAPTER"; then
  echo "generate-selfhost-bundle self-test: missing selfhost_cli_adapter_sources export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! rg -q '^export let selfhost_cli_adapter_source_groups' "$OUT_ADAPTER"; then
  echo "generate-selfhost-bundle self-test: missing selfhost_cli_adapter_source_groups export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! rg -q '^export let selfhost_cli_adapter_ordered_sources' "$OUT_ADAPTER"; then
  echo "generate-selfhost-bundle self-test: missing selfhost_cli_adapter_ordered_sources export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! rg -q '^export let selfhost_cli_adapter_merged_source' "$OUT_ADAPTER"; then
  echo "generate-selfhost-bundle self-test: missing selfhost_cli_adapter_merged_source export" >&2
  cat "$OUT_ADAPTER" >&2
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

adapter_sources_block="$(sed -n '/export let selfhost_cli_adapter_sources/,/^}/p' "$OUT_ADAPTER")"
adapter_merged_block="$(sed -n '/export let selfhost_cli_adapter_merged_source/,/^}/p' "$OUT_ADAPTER")"

if ! printf '%s\n' "$adapter_sources_block" | rg -Fq 'Array::push(sources, source_1)'; then
  echo "generate-selfhost-bundle self-test: adapter closure missing token source" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_sources_block" | rg -Fq 'Array::push(sources, source_1)'; then
  echo "generate-selfhost-bundle self-test: adapter closure missing adapter source" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_sources_block" | rg -Fq 'Array::push(sources, source_2)'; then
  echo "generate-selfhost-bundle self-test: adapter closure unexpectedly kept unrelated index source" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_merged_block" | rg -Fq 'selfhost_cli_adapter_ordered_sources'; then
  echo "generate-selfhost-bundle self-test: adapter merged source should be exact merged text, not raw ordered concat" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_merged_block" | rg -Fq 'let token = polyfill'; then
  echo "generate-selfhost-bundle self-test: adapter merged source missing inlined dependency body" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_merged_block" | rg -Fq 'import ./token.vibe'; then
  echo "generate-selfhost-bundle self-test: adapter merged source still contains import statements" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_merged_block" | rg -Fq '  "\\n'; then
  echo "generate-selfhost-bundle self-test: adapter merged source unexpectedly starts with a blank line" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

echo "generate-selfhost-bundle self-test: ok"
