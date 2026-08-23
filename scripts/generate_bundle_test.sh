#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_SCRIPT="$SCRIPT_DIR/generate_bundle.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_bundle_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/lib/@vibe/compiler"

cat > "$TMP_ROOT/lib/@vibe/compiler/compiler_sources_manifest.tsv" <<'EOF'
# group	path
core	polyfill.vibe
syntax	token.vibe
entry	index.vibe
entry	cli_adapter.vibe
entry	cli_adapter_bundle.vibe
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/polyfill.vibe" <<'EOF'
let polyfill = () -> Int { 1 }
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/token.vibe" <<'EOF'
import ./polyfill.vibe { polyfill }

let token = () -> Int { polyfill() }
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/index.vibe" <<'EOF'
import ./cli_adapter_bundle.vibe { cli_adapter_merged_source }

let index = String::length(cli_adapter_merged_source()) + token()
EOF

cat > "$TMP_ROOT/lib/@vibe/compiler/cli_adapter.vibe" <<'EOF'
import ./token.vibe { token }

let ignored = 1
let cli_main = () -> Int { token() }
EOF

VIBE_PROJECT_ROOT="$TMP_ROOT" \
VIBE_SOURCE_MANIFEST="$TMP_ROOT/lib/@vibe/compiler/compiler_sources_manifest.tsv" \
VIBE_BUNDLE_OUT="$TMP_ROOT/lib/@vibe/compiler/compiler_sources_bundle.vibe" \
VIBE_ADAPTER_BUNDLE_OUT="$TMP_ROOT/lib/@vibe/compiler/cli_adapter_bundle.vibe" \
VIBE_ADAPTER_MODULE_SOURCE_OUT="$TMP_ROOT/lib/@vibe/compiler/cli_adapter_module_source.vibe" \
VIBE_BUNDLE_EXTRA_ENTRIES="" \
VIBE_ADAPTER_MODULE_SOURCE_FROM_MERGED=1 \
bash "$BUNDLE_SCRIPT" >/dev/null

OUT="$TMP_ROOT/lib/@vibe/compiler/compiler_sources_bundle.vibe"
OUT_ADAPTER="$TMP_ROOT/lib/@vibe/compiler/cli_adapter_bundle.vibe"
OUT_ADAPTER_MODULE="$TMP_ROOT/lib/@vibe/compiler/cli_adapter_module_source.vibe"
if [ ! -f "$OUT" ]; then
  echo "generate-bundle self-test: expected bundle output" >&2
  exit 1
fi

if [ ! -f "$OUT_ADAPTER" ]; then
  echo "generate-bundle self-test: expected adapter bundle output" >&2
  exit 1
fi

if [ ! -f "$OUT_ADAPTER_MODULE" ]; then
  echo "generate-bundle self-test: expected adapter module source output" >&2
  exit 1
fi

# Main bundle should contain only files reachable from cli_adapter.vibe
# (+ any extra entries specified via VIBE_BUNDLE_EXTRA_ENTRIES)
# In this test: polyfill, token, cli_adapter are reachable.
# index.vibe is NOT reachable from adapter (it imports adapter_bundle, not adapter).
for path in polyfill token cli_adapter; do
  if ! grep -qE "\"lib/@vibe/compiler/${path}\\.vibe\"" "$OUT"; then
    echo "generate-bundle self-test: missing ${path}.vibe entry" >&2
    cat "$OUT" >&2
    exit 1
  fi
done

# index.vibe should NOT be in the main bundle (unreachable from adapter)
if grep -qE '"lib/@vibe/compiler/index\.vibe"' "$OUT"; then
  echo "generate-bundle self-test: index.vibe should be filtered out (unreachable)" >&2
  cat "$OUT" >&2
  exit 1
fi

polyfill_line="$(grep -nE '"lib/@vibe/compiler/polyfill\.vibe"' "$OUT" | cut -d: -f1)"
token_line="$(grep -nE '"lib/@vibe/compiler/token\.vibe"' "$OUT" | cut -d: -f1)"
adapter_line="$(grep -nE '"lib/@vibe/compiler/cli_adapter\.vibe"' "$OUT" | cut -d: -f1)"

if [ "$polyfill_line" -ge "$token_line" ] || [ "$token_line" -ge "$adapter_line" ]; then
  echo "generate-bundle self-test: manifest order was not preserved" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -qE 'export let compiler_source_groups' "$OUT"; then
  echo "generate-bundle self-test: missing compiler_source_groups export" >&2
  cat "$OUT" >&2
  exit 1
fi

if grep -qE '^export let cli_adapter_sources' "$OUT"; then
  echo "generate-bundle self-test: main bundle unexpectedly exports adapter closure" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -qE '^export let cli_adapter_sources' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: missing cli_adapter_sources export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qE '^export let cli_adapter_source_groups' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: missing cli_adapter_source_groups export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qE '^export let cli_adapter_ordered_sources' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: missing cli_adapter_ordered_sources export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qE '^export let cli_adapter_merged_source' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: missing cli_adapter_merged_source export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qE '^export let cli_adapter_module_source' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: missing cli_adapter_module_source export" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qF 'push_grouped_source_pair(groups, "core", source_0)' "$OUT"; then
  echo "generate-bundle self-test: missing core group mapping" >&2
  cat "$OUT" >&2
  exit 1
fi

if ! grep -qF 'push_grouped_source_pair(groups, "syntax", source_1)' "$OUT"; then
  echo "generate-bundle self-test: missing syntax group mapping" >&2
  cat "$OUT" >&2
  exit 1
fi

# source_2 is cli_adapter.vibe (entry group)
if ! grep -qF 'push_grouped_source_pair(groups, "entry", source_2)' "$OUT"; then
  echo "generate-bundle self-test: missing entry group mapping" >&2
  cat "$OUT" >&2
  exit 1
fi

adapter_sources_block="$(sed -n '/export let cli_adapter_sources/,/^}/p' "$OUT_ADAPTER")"
adapter_merged_block="$(sed -n '/export let cli_adapter_merged_source/,/^}/p' "$OUT_ADAPTER")"
adapter_module_block="$(sed -n '/export let cli_adapter_module_source/,/^}/p' "$OUT_ADAPTER")"
adapter_merged_value_block="$(sed -n '/let cli_adapter_merged_source_value =/,/export let cli_adapter_merged_source/p' "$OUT_ADAPTER")"
adapter_module_value_block="$(sed -n '/let cli_adapter_module_source_value =/,/export let cli_adapter_module_source/p' "$OUT_ADAPTER")"

if ! printf '%s\n' "$adapter_sources_block" | grep -qF 'Array::push(sources, cli_adapter_source_1)'; then
  echo "generate-bundle self-test: adapter closure missing token source" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_sources_block" | grep -qF 'Array::push(sources, cli_adapter_source_2)'; then
  echo "generate-bundle self-test: adapter closure missing adapter source" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_sources_block" | grep -qF 'lib/@vibe/compiler/index.vibe'; then
  echo "generate-bundle self-test: adapter closure unexpectedly kept unrelated index source" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_merged_block" | grep -qF 'cli_adapter_ordered_sources'; then
  echo "generate-bundle self-test: adapter merged source should be exact merged text, not raw ordered concat" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qF 'let cli_adapter_merged_source_value =' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: adapter merged source should be bound as a direct string value" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qF 'let cli_adapter_module_source_value =' "$OUT_ADAPTER"; then
  echo "generate-bundle self-test: adapter module source should be bound as a direct string value" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_merged_block" | grep -qF 'cli_adapter_merged_source_value'; then
  echo "generate-bundle self-test: adapter merged source should rebuild from the direct string binding" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_module_block" | grep -qF 'cli_adapter_module_source_value'; then
  echo "generate-bundle self-test: adapter module source should rebuild from the direct string binding" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_merged_value_block" | grep -qF 'let token = () -> Int { polyfill() }'; then
  echo "generate-bundle self-test: adapter merged source missing inlined dependency body" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if printf '%s\n' "$adapter_merged_value_block" | grep -qF 'import ./token.vibe'; then
  echo "generate-bundle self-test: adapter merged source still contains import statements" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! printf '%s\n' "$adapter_module_value_block" | grep -qF 'let cli_main = () -> Int { token() }'; then
  echo "generate-bundle self-test: adapter module source missing cli_main function" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if ! grep -qF 'let cli_main = () -> Int { token() }' "$OUT_ADAPTER_MODULE"; then
  echo "generate-bundle self-test: adapter module source file missing cli_main function" >&2
  cat "$OUT_ADAPTER_MODULE" >&2
  exit 1
fi

if printf '%s\n' "$adapter_module_value_block" | grep -qF 'let ignored = 1'; then
  echo "generate-bundle self-test: adapter module source should drop non-function lets" >&2
  cat "$OUT_ADAPTER" >&2
  exit 1
fi

if grep -qF 'let ignored = 1' "$OUT_ADAPTER_MODULE"; then
  echo "generate-bundle self-test: adapter module source file should drop non-function lets" >&2
  cat "$OUT_ADAPTER_MODULE" >&2
  exit 1
fi

echo "generate-bundle self-test: ok"
