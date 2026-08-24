#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
node "$SCRIPT_DIR/generate_runtime_fixture_tests.test.mjs"
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
if ! grep -qE 'ARCH999' "$TMP_ROOT/fail.out"; then
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

# A cited path that exists only as an untracked working-tree file must not make
# a staged document pass. CI checks a clean checkout, so the hook must resolve
# citations against the staged snapshot too.
git -C "$TMP_ROOT" checkout -- lib/@vibe/compiler/checker/pass.vibe
mkdir -p "$TMP_ROOT/docs" "$TMP_ROOT/vendor/local-only"
cat > "$TMP_ROOT/docs/reference.md" <<'EOF'
See `vendor/local-only/schema.wit`.
EOF
: > "$TMP_ROOT/vendor/local-only/schema.wit"
git -C "$TMP_ROOT" add docs/reference.md

if VIBE_PRECOMMIT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_ARCH_LINT_RULES="$TMP_ROOT/scripts-rules.tsv" \
  VIBE_ARCH_LINT_ALLOWLIST="$TMP_ROOT/scripts-allowlist.tsv" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/citation-fail.out" 2>&1; then
  echo "precommit self-test: untracked cited path hid a staged dangling citation" >&2
  exit 1
fi
if ! grep -qE 'vendor/local-only/schema.wit' "$TMP_ROOT/citation-fail.out"; then
  echo "precommit self-test: missing staged dangling-citation diagnostic" >&2
  cat "$TMP_ROOT/citation-fail.out" >&2
  exit 1
fi

echo "precommit self-test: ok"
