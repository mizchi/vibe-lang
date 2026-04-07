#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_check_command_parity}"
COMPONENT_PATH="$OUT_DIR/selfhost_check_command.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_check_command.component.wit"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"
WASMTIME_WASI_FLAGS="${VIBE_WASMTIME_WASI_FLAGS:-cli=y}"

mkdir -p "$OUT_DIR"

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native src/cmd/vibe --warn-list '-29'
fi

bash "$PROJECT_ROOT/scripts/build_selfhost_check_command_component.sh" "$COMPONENT_PATH" "$WIT_PATH"

if ! grep -q 'export wasi:cli/run@0.2.6;' "$WIT_PATH"; then
  echo "selfhost check command parity gate failed: component wit is not command-shaped" >&2
  exit 1
fi

cat >"$OUT_DIR/ok.vibe" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF

cat >"$OUT_DIR/parse_error.vibe" <<'EOF'
let answer = (
EOF

check_case() {
  local slug="$1"
  local path="$OUT_DIR/$slug.vibe"
  local host_stdout="$OUT_DIR/$slug.host.stdout"
  local host_stderr="$OUT_DIR/$slug.host.stderr"

  local host_status
  if env VIBE_CHECK_DEBUG=0 "$VIBE_BIN" check "$path" >"$host_stdout" 2>"$host_stderr"; then
    host_status=0
  else
    host_status=$?
  fi

  local self_status
  local self_report
  set +e
  self_report="$(
    env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
      VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
      "$WASMTIME_RUN" run "$COMPONENT_PATH" <"$path"
  )"
  self_status=$?
  set -e

  if [ "$slug" = "ok" ]; then
    if [ "$host_status" -ne 0 ] || [ "$self_status" -ne 0 ]; then
      echo "selfhost check command parity failed: ok case status host=$host_status self=$self_status" >&2
      exit 1
    fi
    if [ "$self_report" != "ok" ]; then
      echo "selfhost check command parity failed: ok case report '$self_report'" >&2
      exit 1
    fi
  else
    if [ "$host_status" -eq 0 ] || [ "$self_status" -eq 0 ]; then
      echo "selfhost check command parity failed: error case '$slug' status host=$host_status self=$self_status" >&2
      exit 1
    fi
    case "$self_report" in
      error:*)
        ;;
      *)
        echo "selfhost check command parity failed: error case '$slug' report '$self_report'" >&2
        exit 1
        ;;
    esac
  fi
}

check_case ok
check_case parse_error

echo "selfhost check command parity gate passed"
