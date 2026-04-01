#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
NORMALIZE_SCRIPT="$SCRIPT_DIR/vibe_normalize_all.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_normalize_all_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/vibe/pkg"
for name in a b c d e; do
  cat > "$TMP_ROOT/vibe/pkg/${name}.vibe" <<EOF
let ${name} = 1
EOF
done

cat > "$TMP_ROOT/vibe/pkg/selfhost_sources_bundle.vibe" <<'EOF'
let generated = 1
EOF

cat > "$TMP_ROOT/vibe/pkg/selfhost_cli_adapter_bundle.vibe" <<'EOF'
let generated = 1
EOF

cat > "$TMP_ROOT/vibe/pkg/selfbuild_runtime_entry_bundle.vibe" <<'EOF'
let generated = 1
EOF

LOG_FILE="$TMP_ROOT/normalize_calls.log"
FAKE_BIN="$TMP_ROOT/fake_vibe.sh"
cat > "$FAKE_BIN" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "$1" != "normalize" ]; then
  echo "unexpected command: $1" >&2
  exit 1
fi
shift
if [ "$1" != "--check" ] && [ "$1" != "--write" ]; then
  echo "unexpected mode: $1" >&2
  exit 1
fi
shift
printf '%s\n' "$#" >> "$LOG_FILE"
printf '%s\n' "$*" >> "$LOG_FILE.args"
EOF
chmod +x "$FAKE_BIN"

LOG_FILE="$LOG_FILE" \
VIBE_NORMALIZE_BIN="$FAKE_BIN" \
VIBE_NORMALIZE_BATCH_SIZE=2 \
VIBE_NORMALIZE_EXCLUDE_FILES="$TMP_ROOT/vibe/pkg/selfhost_sources_bundle.vibe $TMP_ROOT/vibe/pkg/selfhost_cli_adapter_bundle.vibe $TMP_ROOT/vibe/pkg/selfbuild_runtime_entry_bundle.vibe" \
bash "$NORMALIZE_SCRIPT" --check "$TMP_ROOT/vibe" >/dev/null

expected=$'2\n2\n1'
actual="$(cat "$LOG_FILE")"
if [ "$actual" != "$expected" ]; then
  echo "vibe-normalize-all self-test: expected batch sizes 2/2/1, got:" >&2
  printf '%s\n' "$actual" >&2
  exit 1
fi

for excluded in \
  selfhost_sources_bundle.vibe \
  selfhost_cli_adapter_bundle.vibe \
  selfbuild_runtime_entry_bundle.vibe
do
  if grep -q "$excluded" "$LOG_FILE.args"; then
    echo "vibe-normalize-all self-test: excluded generated file was normalized: $excluded" >&2
    exit 1
  fi
done

echo "vibe-normalize-all self-test: ok"
