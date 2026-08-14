#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/lint_review_regressions.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_review_lint_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" config user.email test@example.com
git -C "$TMP_ROOT" config user.name test
mkdir -p "$TMP_ROOT/lib/@vibe/compiler/normalize"

cat > "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn rewrite(e: Expr) -> Expr { e }
EOF
git -C "$TMP_ROOT" add .
git -C "$TMP_ROOT" commit -qm base

cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn bad(e: Expr) -> Expr { ELet("__fixed_tmp", e, e, -1) }
EOF
git -C "$TMP_ROOT" add .

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$TMP_ROOT/fail.out" 2>&1; then
  echo "review-regressions lint self-test: expected fixed synthetic binder violation" >&2
  exit 1
fi
if ! rg -q 'fixed synthetic binder' "$TMP_ROOT/fail.out"; then
  echo "review-regressions lint self-test: missing violation diagnostic" >&2
  cat "$TMP_ROOT/fail.out" >&2
  exit 1
fi

git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn builtin_ref() -> Expr { EIdent("__to_string", -1) }
EOF
git -C "$TMP_ROOT" add .
VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >/dev/null

cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn reserved(e: Expr) -> Expr { SLet(false, false, "__abi_entry", None, e) } // review-lint: allow-fixed-synthetic-name -- reserved ABI binding
EOF
git -C "$TMP_ROOT" add .
VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >/dev/null

git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn ast_bad(e: Expr) -> Expr {
  ELet(
    "__multiline_tmp",
    e,
    e,
    -1,
  )
}
EOF
git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/fake-vibe" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *'SLet('* ]]; then
  echo '[]'
else
  jq -n --arg path "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" \
    '[{path:\$path,line:3,col:1,start:1,end:2,text:"ELet(\\"__multiline_tmp\\", e, e, -1)",captures:{ctor:{text:"ELet",start:1},name:{text:"\\"__multiline_tmp\\"",start:2},rest:{text:"e, e, -1",start:3}}}]'
fi
EOF
chmod +x "$TMP_ROOT/fake-vibe"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/ast-fail.out" 2>&1; then
  echo "review-regressions lint self-test: expected AST backend violation" >&2
  exit 1
fi
if ! rg -q '__multiline_tmp' "$TMP_ROOT/ast-fail.out"; then
  echo "review-regressions lint self-test: AST backend lost the capture" >&2
  cat "$TMP_ROOT/ast-fail.out" >&2
  exit 1
fi

echo "review-regressions lint self-test: ok"
