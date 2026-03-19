#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
TMP_DIR="$(mktemp -d "/tmp/vibe_compiled_http_policy.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

SRC_PATH="$TMP_DIR/http_policy_probe.vibe"
REQUEST_SRC_PATH="$TMP_DIR/http_policy_request_probe.vibe"
LISTEN_SRC_PATH="$TMP_DIR/http_policy_listen_probe.vibe"
VIBE_BIN="${VIBE_BIN:-$VIBE_CLI_BIN}"

cat >"$SRC_PATH" <<'EOF'
let main = () -> Int with {Net} {
  if false {
    let _req = http_request("GET", "https://example.com", "", "")
    0
  } else {
    1
  }
}
main()
EOF

cat >"$REQUEST_SRC_PATH" <<'EOF'
let main = () -> Int with {Net} {
  let req = http_request("GET", "https://example.com", "", "")
  let status = http_response_status(req)
  http_close(req)
  status
}
main()
EOF

cat >"$LISTEN_SRC_PATH" <<'EOF'
let main = () -> Int with {Net} {
  let _listener = http_listen(8080)
  1
}
main()
EOF

AUTO_OUT="$TMP_DIR/auto.out"
AUTO_ERR="$TMP_DIR/auto.err"

if ! "$VIBE_BIN" run "$SRC_PATH" >"$AUTO_OUT" 2>"$AUTO_ERR"; then
  echo "compiled backend http policy failed: auto backend run should succeed" >&2
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
if ! VIBE_RUN_BACKEND=compiled "$VIBE_BIN" run "$SRC_PATH" >"$FORCED_OUT" 2>"$FORCED_ERR"; then
  echo "compiled backend http policy failed: forced compiled backend should succeed" >&2
  cat "$FORCED_OUT" >&2 || true
  cat "$FORCED_ERR" >&2 || true
  exit 1
fi
if ! rg -n '^last: 1$' "$FORCED_OUT" >/dev/null; then
  echo "compiled backend http policy failed: forced compiled backend output missing 'last: 1'" >&2
  cat "$FORCED_OUT" >&2 || true
  cat "$FORCED_ERR" >&2 || true
  exit 1
fi

DENY_CONNECT_OUT="$TMP_DIR/deny_connect.out"
DENY_CONNECT_ERR="$TMP_DIR/deny_connect.err"
if VIBE_RUN_BACKEND=compiled VIBE_HTTP_ALLOW_CONNECT= VIBE_HTTP_ALLOW_LISTEN='*' "$VIBE_BIN" run "$REQUEST_SRC_PATH" >"$DENY_CONNECT_OUT" 2>"$DENY_CONNECT_ERR"; then
  echo "compiled backend http policy failed: deny-connect run should fail" >&2
  cat "$DENY_CONNECT_OUT" >&2 || true
  cat "$DENY_CONNECT_ERR" >&2 || true
  exit 1
fi
if ! rg -n 'PermissionDenied: net_connect:example.com:443' "$DENY_CONNECT_OUT" "$DENY_CONNECT_ERR" >/dev/null; then
  echo "compiled backend http policy failed: deny-connect message mismatch" >&2
  cat "$DENY_CONNECT_OUT" >&2 || true
  cat "$DENY_CONNECT_ERR" >&2 || true
  exit 1
fi

ALLOW_CONNECT_OUT="$TMP_DIR/allow_connect.out"
ALLOW_CONNECT_ERR="$TMP_DIR/allow_connect.err"
if ! VIBE_RUN_BACKEND=compiled VIBE_HTTP_ALLOW_CONNECT='example.com:443' VIBE_HTTP_ALLOW_LISTEN= "$VIBE_BIN" run "$REQUEST_SRC_PATH" >"$ALLOW_CONNECT_OUT" 2>"$ALLOW_CONNECT_ERR"; then
  echo "compiled backend http policy failed: allow-connect run should succeed" >&2
  cat "$ALLOW_CONNECT_OUT" >&2 || true
  cat "$ALLOW_CONNECT_ERR" >&2 || true
  exit 1
fi
if ! rg -n '^last: 200$' "$ALLOW_CONNECT_OUT" >/dev/null; then
  echo "compiled backend http policy failed: allow-connect output missing 'last: 200'" >&2
  cat "$ALLOW_CONNECT_OUT" >&2 || true
  cat "$ALLOW_CONNECT_ERR" >&2 || true
  exit 1
fi

DENY_LISTEN_OUT="$TMP_DIR/deny_listen.out"
DENY_LISTEN_ERR="$TMP_DIR/deny_listen.err"
if VIBE_RUN_BACKEND=compiled VIBE_HTTP_ALLOW_CONNECT='*' VIBE_HTTP_ALLOW_LISTEN= "$VIBE_BIN" run "$LISTEN_SRC_PATH" >"$DENY_LISTEN_OUT" 2>"$DENY_LISTEN_ERR"; then
  echo "compiled backend http policy failed: deny-listen run should fail" >&2
  cat "$DENY_LISTEN_OUT" >&2 || true
  cat "$DENY_LISTEN_ERR" >&2 || true
  exit 1
fi
if ! rg -n 'PermissionDenied: net_listen:8080' "$DENY_LISTEN_OUT" "$DENY_LISTEN_ERR" >/dev/null; then
  echo "compiled backend http policy failed: deny-listen message mismatch" >&2
  cat "$DENY_LISTEN_OUT" >&2 || true
  cat "$DENY_LISTEN_ERR" >&2 || true
  exit 1
fi

ALLOW_LISTEN_OUT="$TMP_DIR/allow_listen.out"
ALLOW_LISTEN_ERR="$TMP_DIR/allow_listen.err"
if ! VIBE_RUN_BACKEND=compiled VIBE_HTTP_ALLOW_CONNECT= VIBE_HTTP_ALLOW_LISTEN='8080' "$VIBE_BIN" run "$LISTEN_SRC_PATH" >"$ALLOW_LISTEN_OUT" 2>"$ALLOW_LISTEN_ERR"; then
  echo "compiled backend http policy failed: allow-listen run should succeed" >&2
  cat "$ALLOW_LISTEN_OUT" >&2 || true
  cat "$ALLOW_LISTEN_ERR" >&2 || true
  exit 1
fi
if ! rg -n '^last: 1$' "$ALLOW_LISTEN_OUT" >/dev/null; then
  echo "compiled backend http policy failed: allow-listen output missing 'last: 1'" >&2
  cat "$ALLOW_LISTEN_OUT" >&2 || true
  cat "$ALLOW_LISTEN_ERR" >&2 || true
  exit 1
fi

echo "compiled backend http policy passed"
