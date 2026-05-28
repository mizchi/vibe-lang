#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/lint_tracked_experiment_names.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_experiment_name_lint_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$TMP_ROOT" init -q
mkdir -p "$TMP_ROOT/vibe/compiler" "$TMP_ROOT/scripts"

cat > "$TMP_ROOT/vibe/compiler/cache_probe_test.vibe" <<'EOF'
test "allowed legacy probe" { assert(true) }
EOF

cat > "$TMP_ROOT/vibe/compiler/new_probe_test.vibe" <<'EOF'
test "new probe" { assert(true) }
EOF

cat > "$TMP_ROOT/scripts/.tmp_probe.sh" <<'EOF'
echo tmp
EOF

git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/allowlist.txt" <<'EOF'
# path
vibe/compiler/cache_probe_test.vibe
EOF

if VIBE_EXPERIMENT_NAME_LINT_ROOT="$TMP_ROOT" \
  VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST="$TMP_ROOT/allowlist.txt" \
  bash "$CHECK_SCRIPT" >"$TMP_ROOT/fail.stdout" 2>"$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: expected unallowlisted probe failure" >&2
  exit 1
fi

if ! rg -q 'vibe/compiler/new_probe_test.vibe' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: missing new probe violation" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

if ! rg -q 'scripts/.tmp_probe.sh' "$TMP_ROOT/fail.stderr"; then
  echo "experiment-name lint self-test: missing .tmp violation" >&2
  cat "$TMP_ROOT/fail.stderr" >&2
  exit 1
fi

cat >> "$TMP_ROOT/allowlist.txt" <<'EOF'
vibe/compiler/new_probe_test.vibe
scripts/.tmp_probe.sh
EOF

VIBE_EXPERIMENT_NAME_LINT_ROOT="$TMP_ROOT" \
  VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST="$TMP_ROOT/allowlist.txt" \
  bash "$CHECK_SCRIPT" >/dev/null

echo "experiment-name lint self-test: ok"
