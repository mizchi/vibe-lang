#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SYNC_SCRIPT="$SCRIPT_DIR/sync_vibe_index_vbundle.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_sync_vbundle_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/vibe/pkg"

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./main.vibe":"#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF

VIBE_LOCK_SYNC_ROOT="$TMP_ROOT" bash "$SYNC_SCRIPT" >/dev/null

if [ ! -f "$TMP_ROOT/vibe/pkg/index.vbundle" ]; then
  echo "sync-vbundle self-test: expected index.vbundle to be created" >&2
  exit 1
fi

if ! jq -e '.lock.path["./main.vibe"] == "#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$TMP_ROOT/vibe/pkg/index.vbundle" >/dev/null; then
  echo "sync-vbundle self-test: generated index.vbundle missing lock payload" >&2
  exit 1
fi

cat > "$TMP_ROOT/vibe/pkg/index.lock" <<'EOF'
{"path":{"./next.vibe":"#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
EOF

cat > "$TMP_ROOT/vibe/pkg/index.vbundle" <<'EOF'
{"graph_head":"head-1","lock":{"path":{"./stale.vibe":"#cccccccccccccccccccccccccccccccccccccccc"}}}
EOF

VIBE_LOCK_SYNC_ROOT="$TMP_ROOT" bash "$SYNC_SCRIPT" >/dev/null

if ! jq -e '.graph_head == "head-1"' "$TMP_ROOT/vibe/pkg/index.vbundle" >/dev/null; then
  echo "sync-vbundle self-test: existing metadata should be preserved" >&2
  exit 1
fi

if ! jq -e '.lock.path["./next.vibe"] == "#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$TMP_ROOT/vibe/pkg/index.vbundle" >/dev/null; then
  echo "sync-vbundle self-test: lock payload should be refreshed" >&2
  exit 1
fi

echo "sync-vbundle self-test: ok"
