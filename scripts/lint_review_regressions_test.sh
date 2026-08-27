#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The self-test must not inherit its own answer. `.claude/hooks/session-start.sh`
# EXPORTS `VIBE_REVIEW_LINT_GREP_BIN`, and inheriting it silently turned the
# three "AST tier skipped" cases at the bottom of this file into no-ops: the
# tier ran, so no WARNING was printed and the test failed with "a skipped AST
# tier did not print the WARNING summary" (#2252). Every case below sets the
# variables it depends on explicitly, so clearing them here is what makes the
# result a property of the lint rather than of the machine.
unset VIBE_REVIEW_LINT_GREP_BIN
unset VIBE_REVIEW_LINT_RUNNER
unset VIBE_REVIEW_LINT_REQUIRE_AST
unset VIBE_REVIEW_LINT_PROJECT_ROOT
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
if ! grep -qE '__fixed_tmp' "$TMP_ROOT/fail.out"; then
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

# --- the marker on the line AFTER the binder (#2363) --------------------------
# `pkf run fmt` moves a trailing comment onto the next line, so this is the
# shape the suppression actually has everywhere lib/** is formatted. An
# exact-line test made the documented form unusable; this case is why the
# check accepts line + 1.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn formatted(e: Expr) -> Expr {
  ELet("__fmt_tmp", e, e, -1)
  // review-lint: allow-fixed-synthetic-name -- marker moved down by the formatter
}
EOF
git -C "$TMP_ROOT" add .
if ! VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$TMP_ROOT/fmt.out" 2>&1; then
  echo "review-regressions lint self-test: a marker on the NEXT line must suppress" >&2
  cat "$TMP_ROOT/fmt.out" >&2
  exit 1
fi

# --- ADJACENCY: one marker must not cover two binders (#2366 review) ----------
# Two binders, but only the FIRST is marked. Accepting `line - 1` would let the
# first binder's marker suppress the second, so an unreviewed fixed synthetic
# binder would evade the lint entirely. The second binder MUST still be
# reported.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EOF'
fn adjacent(e: Expr) -> Expr {
  ELet("__adj_marked", e, e, -1)
  // review-lint: allow-fixed-synthetic-name -- belongs to __adj_marked only
  ELet("__adj_unmarked", e, e, -1)
}
EOF
git -C "$TMP_ROOT" add .
if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$TMP_ROOT/adj.out" 2>&1; then
  echo "review-regressions lint self-test: an unmarked binder next to a marked one must still be reported" >&2
  cat "$TMP_ROOT/adj.out" >&2
  exit 1
fi
if ! grep -q '__adj_unmarked' "$TMP_ROOT/adj.out"; then
  echo "review-regressions lint self-test: adjacency case reported the wrong binder" >&2
  cat "$TMP_ROOT/adj.out" >&2
  exit 1
fi
if grep -q '__adj_marked' "$TMP_ROOT/adj.out"; then
  echo "review-regressions lint self-test: the MARKED binder must stay suppressed" >&2
  cat "$TMP_ROOT/adj.out" >&2
  exit 1
fi

# --- ADJACENCY on the AST tier (#2366 review) --------------------------------
# The case above exercises the AWK fallback. The AST backend resolves the
# suppression in review_lint.vibex::is_allowed -- a DIFFERENT implementation of
# the same rule -- so it needs its own case, or the two tiers can disagree.
# That split is exactly what made this fix necessary: the .vibex tier accepted
# the formatted marker while the fallback still rejected it.
#
# Shape (post-formatter):
#   ELet("__ast_adj_marked", ...)
#   // review-lint: allow-fixed-synthetic-name   <- belongs to the line ABOVE
#   ELet("__ast_adj_unmarked", ...)
# Accepting `line - 1` would let that one marker cover the SECOND binder too.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'ADJEOF'
fn ast_adjacent(e: Expr) -> Expr {
  ELet("__ast_adj_marked", e, e, -1)
  // review-lint: allow-fixed-synthetic-name -- belongs to __ast_adj_marked only
  ELet("__ast_adj_unmarked", e, e, -1)
}
ADJEOF
git -C "$TMP_ROOT" add .

cat > "$TMP_ROOT/fake-vibe-adjacency" <<'FAKEEOF'
#!/usr/bin/env bash
root="${@: -1}"
f="$root/lib/@vibe/compiler/normalize/pass.vibe"
if [[ "$*" == *'SLet('* || "$*" == *'EAssignOp('* || "$*" == *'String::contains('* ]]; then
  echo '[]'; exit 0
fi
m=$(grep -n '__ast_adj_marked' "$f" | head -1 | cut -d: -f1)
u=$(grep -n '__ast_adj_unmarked' "$f" | head -1 | cut -d: -f1)
jq -n --arg path "$f" --argjson m "$m" --argjson u "$u" \
  '[{path:$path,line:$m,col:1,start:1,end:2,text:"ELet(\"__ast_adj_marked\", e, e, -1)",captures:{ctor:{text:"ELet",start:1},name:{text:"\"__ast_adj_marked\"",start:2},rest:{text:"e, e, -1",start:3}}},
    {path:$path,line:$u,col:1,start:1,end:2,text:"ELet(\"__ast_adj_unmarked\", e, e, -1)",captures:{ctor:{text:"ELet",start:1},name:{text:"\"__ast_adj_unmarked\"",start:2},rest:{text:"e, e, -1",start:3}}}]'
FAKEEOF
chmod +x "$TMP_ROOT/fake-vibe-adjacency"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-adjacency" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/ast-adj.out" 2>&1; then
  echo "review-regressions lint self-test: AST tier let an unmarked adjacent binder through" >&2
  cat "$TMP_ROOT/ast-adj.out" >&2
  exit 1
fi
if ! grep -q '__ast_adj_unmarked' "$TMP_ROOT/ast-adj.out"; then
  echo "review-regressions lint self-test: AST adjacency case reported the wrong binder" >&2
  cat "$TMP_ROOT/ast-adj.out" >&2
  exit 1
fi
if grep -q '__ast_adj_marked' "$TMP_ROOT/ast-adj.out"; then
  echo "review-regressions lint self-test: AST tier must keep the MARKED binder suppressed" >&2
  cat "$TMP_ROOT/ast-adj.out" >&2
  exit 1
fi

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
if ! grep -qE '__multiline_tmp' "$TMP_ROOT/ast-fail.out"; then
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
if ! grep -qE 'EAssignOp.*operator' "$TMP_ROOT/assign-op-fail.out"; then
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
if ! grep -qE 'Async effect membership must be exact' "$TMP_ROOT/async-row-fail.out"; then
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
// Documentation-only edit: the historical binder above is unchanged.
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
if ! grep -qE 'EAssignOp.*operator' "$TMP_ROOT/multiline-fail.out"; then
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
if ! grep -qE 'bootstrap failed before lint execution' "$TMP_ROOT/runner-fail.out"; then
  echo "review-regressions lint self-test: runner failure diagnostic was lost" >&2
  cat "$TMP_ROOT/runner-fail.out" >&2
  exit 1
fi
if ! grep -qE 'the AST scan did not run' "$TMP_ROOT/runner-fail.out"; then
  echo "review-regressions lint self-test: runner exit 1 was reported as a finding" >&2
  cat "$TMP_ROOT/runner-fail.out" >&2
  exit 1
fi
if grep -qE 'structural regression\(s\) added' "$TMP_ROOT/runner-fail.out"; then
  echo "review-regressions lint self-test: runner exit 1 accused the staged diff" >&2
  cat "$TMP_ROOT/runner-fail.out" >&2
  exit 1
fi

# A silent runner failure must also fail closed. In this case there is no
# diagnostic text to make `violations` non-empty, so the tool-error flag itself
# must drive the final exit status.
cat > "$TMP_ROOT/fake-vibe-runner-silent-failure" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP_ROOT/fake-vibe-runner-silent-failure"

if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_GREP_BIN="$TMP_ROOT/fake-vibe-runner-silent-failure" \
  VIBE_REVIEW_LINT_RUNNER="$TMP_ROOT/fake-vibe-runner-silent-failure" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/runner-silent-fail.out" 2>&1; then
  echo "review-regressions lint self-test: silent runner exit 1 was ignored" >&2
  exit 1
fi
if ! grep -qE 'the AST scan did not run' "$TMP_ROOT/runner-silent-fail.out"; then
  echo "review-regressions lint self-test: silent runner failure diagnostic was lost" >&2
  cat "$TMP_ROOT/runner-silent-fail.out" >&2
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
if grep -qE 'structural regression\(s\) added' "$TMP_ROOT/unavailable.out"; then
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
if ! grep -qE 'the AST scan did not run' "$TMP_ROOT/scan-error.out"; then
  echo "review-regressions lint self-test: a failed scan was reported as a finding" >&2
  cat "$TMP_ROOT/scan-error.out" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# #1870: a skipped tier must be VISIBLE, and refusable.
#
# The three checks below are the ones whose absence let a real drift through.
# The lint's only enforcement point against a real diff was the pre-commit
# hook; where the runner could not run, the hook dropped its AST tier and
# still printed a bare "ok", so "checked and clean" and "did not check" were
# the same line.

# 1. The skip has to say so in the SUMMARY, not only on stderr. A caller that
#    reads the last line (a human scanning hook output, a script) otherwise
#    cannot tell the two apart. #1988: that line must not start with or equal
#    `ok` -- empty/`ok` output means the AST tier actually ran.
if ! VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  "$CHECK_SCRIPT" >"$TMP_ROOT/skip-summary.out" 2>&1; then
  echo "review-regressions lint self-test: an unrunnable grep must still exit 0 by default" >&2
  exit 1
fi
if ! grep -qE 'WARNING -- AST tier skipped \(text tier only; this is not a clean scan\)' "$TMP_ROOT/skip-summary.out"; then
  echo "review-regressions lint self-test: a skipped AST tier did not print the WARNING summary" >&2
  cat "$TMP_ROOT/skip-summary.out" >&2
  exit 1
fi
if grep -qE '^review-regressions lint: ok' "$TMP_ROOT/skip-summary.out"; then
  echo "review-regressions lint self-test: a skipped AST tier still claimed ok" >&2
  cat "$TMP_ROOT/skip-summary.out" >&2
  exit 1
fi

# 2. VIBE_REVIEW_LINT_REQUIRE_AST=1 turns that skip into a failure. This is
#    what CI sets, so a gate cannot report success having checked nothing.
if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_REQUIRE_AST=1 \
  "$CHECK_SCRIPT" >"$TMP_ROOT/require-ast.out" 2>&1; then
  echo "review-regressions lint self-test: REQUIRE_AST=1 accepted a skipped AST tier" >&2
  cat "$TMP_ROOT/require-ast.out" >&2
  exit 1
fi
if ! grep -qE 'the AST tier is required here and did not run' "$TMP_ROOT/require-ast.out"; then
  echo "review-regressions lint self-test: REQUIRE_AST failure did not say why" >&2
  cat "$TMP_ROOT/require-ast.out" >&2
  exit 1
fi

# 3. The skip flag is keyed to the OUTCOME, not to one branch of the probe.
#    Keyed to "runtime/vibe exists but cannot run", the plainer failure -- no
#    runtime/vibe at all -- fell out of the chain untouched and reported a
#    clean "ok" even under REQUIRE_AST. Measured during #1870; this pins it.
rm -f "$TMP_ROOT/runtime/vibe"
if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" \
  VIBE_REVIEW_LINT_REQUIRE_AST=1 \
  "$CHECK_SCRIPT" >"$TMP_ROOT/no-bin.out" 2>&1; then
  echo "review-regressions lint self-test: REQUIRE_AST passed with no grep binary at all" >&2
  cat "$TMP_ROOT/no-bin.out" >&2
  exit 1
fi


# --- an EDITED binder whose marker already existed (#2366 review, 2nd round) --
# The fallback reads a diff, and `git diff --unified=0` shows only changed
# lines. A marker that was already there is unchanged context and never appears
# in it. Resolving the suppression from the DIFF therefore rejected a binder
# whose marker is sitting one line below it in the file -- while is_allowed(),
# which reads the file, accepted the same staged source. The fallback reads the
# physical next line now, so both tiers answer the same question.
git -C "$TMP_ROOT" reset -q HEAD -- .
git -C "$TMP_ROOT" restore .
cat >> "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe" <<'EDITEOF'
fn preexisting(e: Expr) -> Expr {
  ELet("__preexisting_old", e, e, -1)
  // review-lint: allow-fixed-synthetic-name -- committed before the edit
}
EDITEOF
git -C "$TMP_ROOT" add .
git -C "$TMP_ROOT" -c user.email=selftest@example.com -c user.name=selftest commit -qm "marker committed"

# rename the binder, leaving the marker line untouched
sed -i.bak 's/__preexisting_old/__preexisting_new/' "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe"
rm -f "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe.bak"
git -C "$TMP_ROOT" add .
if ! VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$TMP_ROOT/preexisting.out" 2>&1; then
  echo "review-regressions lint self-test: an UNCHANGED next-line marker must still suppress" >&2
  cat "$TMP_ROOT/preexisting.out" >&2
  exit 1
fi

# and deleting that marker must bring the violation back
sed -i.bak '/review-lint: allow-fixed-synthetic-name -- committed before the edit/d' "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe"
rm -f "$TMP_ROOT/lib/@vibe/compiler/normalize/pass.vibe.bak"
git -C "$TMP_ROOT" add .
if VIBE_REVIEW_LINT_PROJECT_ROOT="$TMP_ROOT" "$CHECK_SCRIPT" >"$TMP_ROOT/preexisting-gone.out" 2>&1; then
  echo "review-regressions lint self-test: deleting the marker must re-report the binder" >&2
  cat "$TMP_ROOT/preexisting-gone.out" >&2
  exit 1
fi
if ! grep -q '__preexisting_new' "$TMP_ROOT/preexisting-gone.out"; then
  echo "review-regressions lint self-test: wrong binder reported after marker deletion" >&2
  cat "$TMP_ROOT/preexisting-gone.out" >&2
  exit 1
fi
git -C "$TMP_ROOT" reset -q --hard HEAD

echo "review-regressions lint self-test: ok"
