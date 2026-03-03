#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="$(mktemp -d "/tmp/vibe_compiled_http_policy.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

SRC_PATH="$TMP_DIR/http_policy_probe.vibe"

cat >"$SRC_PATH" <<'EOF'
let main = () -> Int with {Net} {
  if false {
    let _req = http_request("GET", "https://example.com", "", "")
    0
  } else {
    1
  }
}
EOF

AUTO_OUT="$TMP_DIR/auto.out"
AUTO_ERR="$TMP_DIR/auto.err"

if ! moon run --target native src/cmd/vibe -- run "$SRC_PATH" >"$AUTO_OUT" 2>"$AUTO_ERR"; then
  echo "compiled backend http policy failed: auto backend run should fall back to interpreter" >&2
  cat "$AUTO_ERR" >&2 || true
  exit 1
fi
if ! rg -n '^last: 1$' "$AUTO_OUT" >/dev/null; then
  echo "compiled backend http policy failed: auto backend output missing 'last: 1'" >&2
  cat "$AUTO_OUT" >&2 || true
  cat "$AUTO_ERR" >&2 || true
  exit 1
fi

FORCED_OUT="$TMP_DIR/forced.out"
FORCED_ERR="$TMP_DIR/forced.err"
set +e
VIBE_RUN_BACKEND=compiled moon run --target native src/cmd/vibe -- run "$SRC_PATH" >"$FORCED_OUT" 2>"$FORCED_ERR"
FORCED_STATUS=$?
set -e
if ! rg -n 'compiled backend unsupported: http builtins require interpreter backend' "$FORCED_OUT" "$FORCED_ERR" >/dev/null; then
  echo "compiled backend http policy failed: forced compiled backend error message mismatch" >&2
  echo "status=$FORCED_STATUS" >&2
  cat "$FORCED_OUT" >&2 || true
  cat "$FORCED_ERR" >&2 || true
  exit 1
fi

echo "compiled backend http policy passed"
