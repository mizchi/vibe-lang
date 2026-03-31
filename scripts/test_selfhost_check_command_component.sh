#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_check_command_component}"
COMPONENT_PATH="$OUT_DIR/selfhost_check_command.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_check_command.component.wit"
OK_INPUT="$OUT_DIR/ok.vibe"
ERR_INPUT="$OUT_DIR/error.vibe"
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"
WASMTIME_WASI_FLAGS="${VIBE_WASMTIME_WASI_FLAGS:-cli=y}"

mkdir -p "$OUT_DIR"
cat >"$OK_INPUT" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF
cat >"$ERR_INPUT" <<'EOF'
let answer = (
EOF

bash "$PROJECT_ROOT/scripts/build_selfhost_check_command_component.sh" "$COMPONENT_PATH" "$WIT_PATH"

if ! grep -q 'export wasi:cli/run@0.2.6;' "$WIT_PATH"; then
  echo "selfhost check command component gate failed: component wit is not command-shaped" >&2
  exit 1
fi

OK_REPORT="$(
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
    "$WASMTIME_RUN" run "$COMPONENT_PATH" <"$OK_INPUT"
)"
set +e
ERR_REPORT="$(
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
    "$WASMTIME_RUN" run "$COMPONENT_PATH" <"$ERR_INPUT"
)"
ERR_STATUS=$?
set -e

if [ "$OK_REPORT" != "ok" ]; then
  echo "selfhost check command component gate failed: ok source report '$OK_REPORT'" >&2
  exit 1
fi

if [ "$ERR_STATUS" -eq 0 ]; then
  echo "selfhost check command component gate failed: invalid source returned exit 0" >&2
  exit 1
fi

case "$ERR_REPORT" in
  error:*)
    ;;
  *)
    echo "selfhost check command component gate failed: invalid source report '$ERR_REPORT'" >&2
    exit 1
    ;;
esac

echo "selfhost check command component gate passed"
