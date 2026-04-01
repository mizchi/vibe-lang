#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cli_direct_component}"
COMPONENT_PATH="$OUT_DIR/selfhost_cli_direct.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_cli_direct.component.wit"
INPUT_PATH="$OUT_DIR/input.vibe"
OUTPUT_PATH="$OUT_DIR/output.wasm"
RUN_LOG="$OUT_DIR/output.run.log"

mkdir -p "$OUT_DIR"
printf 'let answer = () -> Int { 40 + 2 }\n' >"$INPUT_PATH"
rm -f "$OUTPUT_PATH" "$RUN_LOG"

bash "$SCRIPT_DIR/build_selfhost_cli_direct_component.sh" "$COMPONENT_PATH" "$WIT_PATH"
bash "$SCRIPT_DIR/run_selfhost_cli_direct_component.sh" "$COMPONENT_PATH" "$INPUT_PATH" "$OUTPUT_PATH" answer mvp

if ! grep -q 'export run-cli-request: func(input-path: string, output-path: string, entry-name: string, mode: string) -> s32;' "$WIT_PATH"; then
  echo "selfhost cli direct component gate failed: unexpected component surface" >&2
  exit 1
fi

wasm-tools validate "$OUTPUT_PATH" >/dev/null
env VIBE_WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}" \
  "$SCRIPT_DIR/wasmtime_run.sh" --invoke _start "$OUTPUT_PATH" >"$RUN_LOG"

RESULT="$(grep -E '^-?[0-9]+$' "$RUN_LOG" | tail -n 1 || true)"
if [ "$RESULT" != "42" ]; then
  echo "selfhost cli direct component gate failed: compiled sample returned '$RESULT' (expected 42)" >&2
  exit 1
fi

cat >"$OUT_DIR/lib.vibe" <<'EOF'
let helper = () -> Int { 40 + 2 }
EOF

cat >"$OUT_DIR/import_main.vibe" <<'EOF'
import ./lib.vibe { helper }
let answer = () -> Int { helper() }
EOF

IMPORT_OUTPUT="$OUT_DIR/import_output.wasm"
rm -f "$IMPORT_OUTPUT"
bash "$SCRIPT_DIR/run_selfhost_cli_direct_component.sh" "$COMPONENT_PATH" "$OUT_DIR/import_main.vibe" "$IMPORT_OUTPUT" answer mvp
wasm-tools validate "$IMPORT_OUTPUT" >/dev/null
env VIBE_WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}" \
  "$SCRIPT_DIR/wasmtime_run.sh" --invoke _start "$IMPORT_OUTPUT" >"$RUN_LOG"
if ! grep -q '^42$' "$RUN_LOG"; then
  echo "selfhost cli direct component gate failed: import case did not run to 42" >&2
  exit 1
fi

echo "selfhost cli direct component gate passed"
