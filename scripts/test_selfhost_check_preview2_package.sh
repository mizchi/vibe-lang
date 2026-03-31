#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_check_preview2_package}"
COMPONENT_PATH="$OUT_DIR/selfhost_check_preview2.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_check_preview2.component.wit"
OK_INPUT="$OUT_DIR/ok.vibe"
ERR_INPUT="$OUT_DIR/error.vibe"

mkdir -p "$OUT_DIR"
cat >"$OK_INPUT" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF
cat >"$ERR_INPUT" <<'EOF'
let answer = (
EOF

bash "$SCRIPT_DIR/build_selfhost_check_preview2_component.sh" "$COMPONENT_PATH" "$WIT_PATH"

if ! grep -q 'export check-source-report: func(source: string) -> string;' "$WIT_PATH"; then
  echo "selfhost check preview2 package gate failed: unexpected component surface" >&2
  exit 1
fi

OK_REPORT="$(bash "$SCRIPT_DIR/run_selfhost_check_preview2_component.sh" "$COMPONENT_PATH" "$OK_INPUT")"
ERR_REPORT="$(bash "$SCRIPT_DIR/run_selfhost_check_preview2_component.sh" "$COMPONENT_PATH" "$ERR_INPUT")"

if [ "$OK_REPORT" != "ok" ]; then
  echo "selfhost check preview2 package gate failed: ok source report '$OK_REPORT'" >&2
  exit 1
fi

case "$ERR_REPORT" in
  error:*)
    ;;
  *)
    echo "selfhost check preview2 package gate failed: invalid source report '$ERR_REPORT'" >&2
    exit 1
    ;;
esac

echo "selfhost check preview2 package gate passed"
