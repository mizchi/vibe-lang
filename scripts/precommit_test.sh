#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/precommit.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_precommit_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" config user.email test@example.com
git -C "$TMP_ROOT" config user.name test
mkdir -p "$TMP_ROOT/lib/@vibe/compiler/checker"

cat > "$TMP_ROOT/scripts-rules.tsv" <<'EOF'
# id	severity	scope	regex	message	issue
ARCH999	error	**/*.vibe	forbidden_arch_call	forbidden in compiler	#999
EOF
: > "$TMP_ROOT/scripts-allowlist.tsv"

cat > "$TMP_ROOT/lib/@vibe/compiler/checker/pass.vibe" <<'EOF'
fn check() -> Bool { true }
EOF
git -C "$TMP_ROOT" add .
git -C "$TMP_ROOT" commit -qm base

cat > "$TMP_ROOT/fake-vibe" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
chmod +x "$TMP_ROOT/fake-vibe"

# The index contains a violation while the working tree is clean. The staged
# snapshot must win, otherwise a partial-stage commit can hide the violation.
cat > "$TMP_ROOT/lib/@vibe/compiler/checker/pass.vibe" <<'EOF'
fn check() -> Bool { forbidden_arch_call() }
EOF
git -C "$TMP_ROOT" add .
cat > "$TMP_ROOT/lib/@vibe/compiler/checker/pass.vibe" <<'EOF'
fn check() -> Bool { true }
EOF

if VIBE_PRECOMMIT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/scripts-rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/scripts-allowlist.tsv" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/fail.out" 2>&1; then
  echo "precommit self-test: staged architecture violation was hidden by working tree" >&2
  exit 1
fi
if ! rg -q 'ARCH999' "$TMP_ROOT/fail.out"; then
  echo "precommit self-test: missing staged architecture diagnostic" >&2
  cat "$TMP_ROOT/fail.out" >&2
  exit 1
fi

# Conversely, an unstaged violation must not block a clean staged snapshot.
git -C "$TMP_ROOT" commit -qm violating-base
git -C "$TMP_ROOT" add .
cat > "$TMP_ROOT/lib/@vibe/compiler/checker/pass.vibe" <<'EOF'
fn check() -> Bool { forbidden_arch_call() }
EOF

VIBE_PRECOMMIT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/scripts-rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/scripts-allowlist.tsv" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe" \
  "$CHECK_SCRIPT" >/dev/null

echo "precommit self-test: ok"
