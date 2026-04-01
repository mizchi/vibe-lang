#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_check_direct_parity}"
COMPONENT_PATH="$OUT_DIR/selfhost_check_direct.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_check_direct.component.wit"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe}"

mkdir -p "$OUT_DIR"

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native --release --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
fi

bash "$SCRIPT_DIR/build_selfhost_check_direct_component.sh" "$COMPONENT_PATH" "$WIT_PATH" >/dev/null

cat >"$OUT_DIR/ok.vibe" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF

cat >"$OUT_DIR/parse_error.vibe" <<'EOF'
let answer = (
EOF

check_case() {
  local slug="$1"
  local path="$OUT_DIR/$slug.vibe"
  local self_report="$OUT_DIR/$slug.self.txt"
  local host_stdout="$OUT_DIR/$slug.host.stdout"
  local host_stderr="$OUT_DIR/$slug.host.stderr"

  local host_status
  if env VIBE_CHECK_DEBUG=0 "$VIBE_BIN" check "$path" >"$host_stdout" 2>"$host_stderr"; then
    host_status=0
  else
    host_status=$?
  fi

  local self_status
  if bash "$SCRIPT_DIR/run_selfhost_check_direct_component.sh" "$COMPONENT_PATH" "$path" "$self_report"; then
    self_status=0
  else
    self_status=$?
  fi

  local self_text
  self_text="$(cat "$self_report")"

  if [ "$slug" = "ok" ]; then
    if [ "$host_status" -ne 0 ] || [ "$self_status" -ne 0 ]; then
      echo "selfhost check direct parity failed: ok case status host=$host_status self=$self_status" >&2
      exit 1
    fi
    if [ "$self_text" != "ok" ]; then
      echo "selfhost check direct parity failed: ok case report '$self_text'" >&2
      exit 1
    fi
  else
    if [ "$host_status" -eq 0 ] || [ "$self_status" -eq 0 ]; then
      echo "selfhost check direct parity failed: error case '$slug' status host=$host_status self=$self_status" >&2
      exit 1
    fi
    case "$self_text" in
      error:*)
        ;;
      *)
        echo "selfhost check direct parity failed: error case '$slug' report '$self_text'" >&2
        exit 1
        ;;
    esac
  fi
}

# The direct check component only sees source text and currently shares
# parse/ok semantics with the host checker. Full diagnostic parity,
# including type errors, stays on the stage1 checker gate.
check_case ok
check_case parse_error

echo "selfhost check direct parity gate passed"
