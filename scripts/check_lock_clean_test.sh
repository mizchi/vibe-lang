#!/bin/bash
# Self-test for lock contamination checker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CHECK_SCRIPT="$SCRIPT_DIR/check_lock_clean.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_lock_clean_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/vibe/pkg"

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./main.vibe":"#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF

cat > "$TMP_ROOT/vibe/pkg/index.vibe" <<'EOF'
export let version = "0.1.0"
EOF

VIBE_LOCK_CHECK_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >/dev/null

cat > "$TMP_ROOT/vibe/pkg/index.vibe" <<'EOF'
export let version: String = "0.1.0"
EOF

VIBE_LOCK_CHECK_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >/dev/null

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./_probe/main.vibe":"#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
EOF

FAIL_LOG="$(mktemp "${TMPDIR:-/tmp}/vibe_lock_clean_fail.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"; rm -f "$FAIL_LOG"' EXIT

if VIBE_LOCK_CHECK_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$FAIL_LOG" 2>&1; then
  echo "lock-check self-test: expected failure for temporary entries" >&2
  exit 1
fi

if ! grep -qE "lock-check: found temporary entries in index.lock" "$FAIL_LOG"; then
  echo "lock-check self-test: missing expected failure message" >&2
  cat "$FAIL_LOG" >&2
  exit 1
fi

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./.vibe_test_wasm_12345_1_0.vibe":"#cccccccccccccccccccccccccccccccccccccccc"}}
EOF

if VIBE_LOCK_CHECK_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$FAIL_LOG" 2>&1; then
  echo "lock-check self-test: expected failure for .vibe_test_wasm contamination" >&2
  exit 1
fi

if ! grep -qE "lock-check: found temporary entries in index.lock" "$FAIL_LOG"; then
  echo "lock-check self-test: missing expected .vibe_test_wasm failure message" >&2
  cat "$FAIL_LOG" >&2
  exit 1
fi

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./.tmp_parity.vibe":"#dddddddddddddddddddddddddddddddddddddddd"}}
EOF

if VIBE_LOCK_CHECK_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$FAIL_LOG" 2>&1; then
  echo "lock-check self-test: expected failure for .tmp contamination" >&2
  exit 1
fi

if ! grep -qE "lock-check: found temporary entries in index.lock" "$FAIL_LOG"; then
  echo "lock-check self-test: missing expected .tmp failure message" >&2
  cat "$FAIL_LOG" >&2
  exit 1
fi

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./main.vibe":"#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF

cat > "$TMP_ROOT/vibe/pkg/index.vibe" <<'EOF'
let version = "0.1.0"
EOF

if VIBE_LOCK_CHECK_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$FAIL_LOG" 2>&1; then
  echo "lock-check self-test: expected failure for invalid index.vibe version export" >&2
  exit 1
fi

if ! grep -qE 'lock-check: index.vibe must include export let version = "x.y.z"' "$FAIL_LOG"; then
  echo "lock-check self-test: missing expected index.vibe failure message" >&2
  cat "$FAIL_LOG" >&2
  exit 1
fi

echo "lock-check self-test: ok"
