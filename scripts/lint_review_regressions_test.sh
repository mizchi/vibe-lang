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
if ! rg -q '__fixed_tmp' "$TMP_ROOT/fail.out"; then
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
root="\${@: -1}"
if [[ "\$*" == *'SLet('* || "\$*" == *'EAssignOp('* || "\$*" == *'String::contains('* ]]; then
  echo '[]'
else
  jq -n --arg path "\$root/lib/@vibe/compiler/normalize/pass.vibe" \
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

# #1657: EAssignOp is (target, operator, value, continuation). Binding the
# second field as a target-like name made multiple passes silently inspect the
# operator string instead of the assignment target.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
mkdir -p "$TMP_ROOT/lib/@vibe/compiler/runtime"
cat > "$TMP_ROOT/lib/@vibe/compiler/runtime/grep.vibe" <<'EOF'
fn bad_order(e: Expr) -> Bool {
  match e { EAssignOp(_, name, _, _) => name == "x", _ => false }
}
EOF
git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/fake-vibe-assign-op" <<EOF
#!/usr/bin/env bash
root="\${@: -1}"
if [[ "\$*" == *'EAssignOp('* ]]; then
  jq -n --arg path "\$root/lib/@vibe/compiler/runtime/grep.vibe" \
    '[{path:\$path,line:2,col:13,start:1,end:2,text:"EAssignOp(_, name, _, _)",captures:{target:{text:"_",start:1},operator:{text:"name",start:2},rest:{text:"_, _",start:3}}}]'
else
  echo '[]'
fi
EOF
chmod +x "$TMP_ROOT/fake-vibe-assign-op"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-assign-op" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/assign-op-fail.out" 2>&1; then
  echo "review-regressions lint self-test: expected EAssignOp field-order violation" >&2
  exit 1
fi
if ! rg -q 'EAssignOp.*operator' "$TMP_ROOT/assign-op-fail.out"; then
  echo "review-regressions lint self-test: missing EAssignOp field-order diagnostic" >&2
  cat "$TMP_ROOT/assign-op-fail.out" >&2
  exit 1
fi

# #1289: raw substring checks let NotAsync/AsyncLike grant Async permission.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
mkdir -p "$TMP_ROOT/lib/@vibe/compiler/entry/source_compile/wasi_only"
cat > "$TMP_ROOT/lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess.vibe" <<'EOF'
fn bad_async_row(row: String) -> Bool { String::contains(row, "Async") }
EOF
git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/fake-vibe-async-row" <<EOF
#!/usr/bin/env bash
root="\${@: -1}"
if [[ "\$*" == *'String::contains('* ]]; then
  jq -n --arg path "\$root/lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess.vibe" \
    '[{path:\$path,line:1,col:42,start:1,end:2,text:"String::contains(row, \\"Async\\")",captures:{row:{text:"row",start:1}}}]'
else
  echo '[]'
fi
EOF
chmod +x "$TMP_ROOT/fake-vibe-async-row"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-async-row" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/async-row-fail.out" 2>&1; then
  echo "review-regressions lint self-test: expected Async substring violation" >&2
  exit 1
fi
if ! rg -q 'Async effect membership must be exact' "$TMP_ROOT/async-row-fail.out"; then
  echo "review-regressions lint self-test: missing Async substring diagnostic" >&2
  cat "$TMP_ROOT/async-row-fail.out" >&2
  exit 1
fi

# Editing a file that contains a historical violation must not reject the
# commit unless the violating expression itself is newly added.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat > "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn historical(e: Expr) -> Expr { ELet("__legacy_tmp", e, e, -1) }
EOF
git -C "$TMP_ROOT" add .
git -C "$TMP_ROOT" commit -qm historical-violation
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn unrelated(e: Expr) -> Expr { e }
EOF
git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/fake-vibe-historical" <<EOF
#!/usr/bin/env bash
root="\${@: -1}"
if [[ "\$*" == *'SLet('* || "\$*" == *'EAssignOp('* || "\$*" == *'String::contains('* ]]; then
  echo '[]'
else
  jq -n --arg path "\$root/lib/@vibe/compiler/normalize/pass.vibe" \
    '[{path:\$path,line:1,col:34,start:1,end:2,text:"ELet(\"__legacy_tmp\", e, e, -1)",captures:{ctor:{text:"ELet",start:1},name:{text:"\"__legacy_tmp\"",start:2},rest:{text:"e, e, -1",start:3}}}]'
fi
EOF
chmod +x "$TMP_ROOT/fake-vibe-historical"

VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-historical" \
  "$CHECK_SCRIPT" >/dev/null

# A changed child line intersects the AST finding even when the constructor's
# opening line is unchanged.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat > "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn assign(e: Expr) -> Expr {
  EAssignOp(
    e,
    op,
    e,
    e,
  )
}
EOF
git -C "$TMP_ROOT" add .
git -C "$TMP_ROOT" commit -qm multiline-base
sed -i.bak 's/^    op,$/    name,/' "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe"
rm "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe.bak"
git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/fake-vibe-multiline" <<EOF
#!/usr/bin/env bash
root="\${@: -1}"
if [[ "\$*" == *'EAssignOp('* ]]; then
  jq -n --arg path "\$root/lib/@vibe/compiler/normalize/pass.vibe" \
    '[{path:\$path,line:2,col:3,start:1,end:2,text:"EAssignOp(\\n  e,\\n  name,\\n  e,\\n  e,\\n)",captures:{target:{text:"e",start:1},operator:{text:"name",start:2},rest:{text:"e, e",start:3}}}]'
else
  echo '[]'
fi
EOF
chmod +x "$TMP_ROOT/fake-vibe-multiline"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-multiline" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/multiline-fail.out" 2>&1; then
  echo "review-regressions lint self-test: changed multiline child escaped AST lint" >&2
  exit 1
fi
if ! rg -q 'EAssignOp.*operator' "$TMP_ROOT/multiline-fail.out"; then
  echo "review-regressions lint self-test: missing multiline span diagnostic" >&2
  cat "$TMP_ROOT/multiline-fail.out" >&2
  exit 1
fi

# An exit-1 from the runner is not a lint result and must fail closed.
cat > "$TMP_ROOT/fake-vibe-runner-failure" <<'EOF'
#!/usr/bin/env bash
echo 'bootstrap failed before lint execution' >&2
exit 1
EOF
chmod +x "$TMP_ROOT/fake-vibe-runner-failure"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-runner-failure" \
  VIBE_REVIEW_LINT_RUNNER="$TMP_ROOT/fake-vibe-runner-failure" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/runner-fail.out" 2>&1; then
  echo "review-regressions lint self-test: runner exit 1 was ignored" >&2
  exit 1
fi
if ! rg -q 'bootstrap failed before lint execution' "$TMP_ROOT/runner-fail.out"; then
  echo "review-regressions lint self-test: runner failure diagnostic was lost" >&2
  cat "$TMP_ROOT/runner-fail.out" >&2
  exit 1
fi

# A runner that cannot run at all is not a finding. Before this, the probe
# accepted `runtime/vibe` on the strength of it being an executable script that
# mentions a `grep` verb -- true in a checkout where `bin/viberun` was never
# built -- so every `vibe grep` failed and the run reported `structural
# regression(s) added` against a diff that had nothing to do with it. Skipping
# is what the probe already does when it works; it just has to say so.
# Written at the default GREP_BIN location so the probe itself is exercised;
# setting VIBE_REVIEW_LINT_GREP_BIN would short-circuit it to "available".
mkdir -p "$TMP_ROOT/runtime"
cat > "$TMP_ROOT/runtime/vibe" <<'EOF'
#!/usr/bin/env bash
# Mimics runtime/vibe's dispatcher shape (it has a `  grep)` case) while
# failing the way a checkout with no built runner does.
case "${1:-}" in
  grep) ;;
esac
echo 'vibe: runner not found or not executable: bin/viberun' >&2
exit 1
EOF
chmod +x "$TMP_ROOT/runtime/vibe"

if ! VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/unavailable.out" 2>&1; then
  echo "review-regressions lint self-test: an unrunnable grep binary must skip, not accuse" >&2
  cat "$TMP_ROOT/unavailable.out" >&2
  exit 1
fi
if rg -q 'structural regression\(s\) added' "$TMP_ROOT/unavailable.out"; then
  echo "review-regressions lint self-test: an unrunnable grep binary was reported as a regression" >&2
  cat "$TMP_ROOT/unavailable.out" >&2
  exit 1
fi

# A runner that IS available but fails mid-scan still fails closed -- and the
# headline says the scan did not run, not that the diff added something.
cat > "$TMP_ROOT/fake-vibe-scan-error" <<'EOF'
#!/usr/bin/env bash
echo 'review-lint: vibe grep failed: backend exploded' >&2
exit 2
EOF
chmod +x "$TMP_ROOT/fake-vibe-scan-error"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-scan-error" \
  VIBE_REVIEW_LINT_RUNNER="$TMP_ROOT/fake-vibe-scan-error" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/scan-error.out" 2>&1; then
  echo "review-regressions lint self-test: a failed scan must fail closed" >&2
  exit 1
fi
if ! rg -q 'the AST scan did not run' "$TMP_ROOT/scan-error.out"; then
  echo "review-regressions lint self-test: a failed scan was reported as a finding" >&2
  cat "$TMP_ROOT/scan-error.out" >&2
  exit 1
fi

echo "review-regressions lint self-test: ok"
