#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_check_direct_component}"
COMPONENT_PATH="$OUT_DIR/selfhost_check_direct.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_check_direct.component.wit"
OK_INPUT="$OUT_DIR/ok.vibe"
ERR_INPUT="$OUT_DIR/error.vibe"
OK_OUTPUT="$OUT_DIR/ok.report.txt"
ERR_OUTPUT="$OUT_DIR/error.report.txt"

mkdir -p "$OUT_DIR"
cat >"$OK_INPUT" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF
cat >"$ERR_INPUT" <<'EOF'
let answer = (
EOF
rm -f "$OK_OUTPUT" "$ERR_OUTPUT"

bash "$SCRIPT_DIR/build_selfhost_check_direct_component.sh" "$COMPONENT_PATH" "$WIT_PATH"

if ! grep -q 'export run-check-request: func(input-path: string, output-path: string) -> s32;' "$WIT_PATH"; then
  echo "selfhost check direct component gate failed: unexpected component surface" >&2
  exit 1
fi

bash "$SCRIPT_DIR/run_check_direct_component.sh" "$COMPONENT_PATH" "$OK_INPUT" "$OK_OUTPUT"
set +e
bash "$SCRIPT_DIR/run_check_direct_component.sh" "$COMPONENT_PATH" "$ERR_INPUT" "$ERR_OUTPUT"
ERR_STATUS=$?
set -e

if [ "$(cat "$OK_OUTPUT")" != "ok" ]; then
  echo "selfhost check direct component gate failed: ok source report '$(cat "$OK_OUTPUT")'" >&2
  exit 1
fi

if [ "$ERR_STATUS" -eq 0 ]; then
  echo "selfhost check direct component gate failed: invalid source returned exit 0" >&2
  exit 1
fi

case "$(cat "$ERR_OUTPUT")" in
  error:*)
    ;;
  *)
    echo "selfhost check direct component gate failed: invalid source report '$(cat "$ERR_OUTPUT")'" >&2
    exit 1
    ;;
esac

echo "selfhost check direct component gate passed"
