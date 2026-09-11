#!/usr/bin/env bash
# Red tests for check_ast_binary_tags.sh (#2510).
#
# Each case mutates a COPY of the real inputs and asserts the gate fails with
# the message for that specific check -- not merely that it failed, since a
# gate that dies for an unrelated reason looks identical to one that works.
# Each case also asserts the mutation LANDED: an edit that matched nothing
# would sail through while proving nothing (#2248).
set -euo pipefail

# The gate reads this; inheriting a value from the surrounding shell (a
# SessionStart hook, a previous case) would silently point every case at the
# wrong tree (#2252).
unset VIBE_AST_BINARY_TAGS_ROOT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/check_ast_binary_tags.sh"
REAL_ROOT="$(dirname "$SCRIPT_DIR")"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ast_binary_tags_test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

VPKG_REL="lib/@vibe/ast/index.vpkg"
DOC_REL="docs/ast_binary_abi.md"

reset_tree() {
  rm -rf "$tmp_root/lib" "$tmp_root/docs"
  mkdir -p "$tmp_root/lib/@vibe/ast" "$tmp_root/docs"
  cp "$REAL_ROOT/$VPKG_REL" "$tmp_root/$VPKG_REL"
  cp "$REAL_ROOT/$DOC_REL" "$tmp_root/$DOC_REL"
}

fail() { echo "check_ast_binary_tags self-test: $1" >&2; exit 1; }

# assert_red <case name> <expected message fragment>
assert_red() {
  name="$1"; want="$2"
  set +e
  VIBE_AST_BINARY_TAGS_ROOT="$tmp_root" bash "$CHECK" > "$tmp_root/out" 2>&1
  st=$?
  set -e
  [ "$st" -ne 0 ] || { cat "$tmp_root/out" >&2; fail "$name: expected a failure, got ok"; }
  grep -q "$want" "$tmp_root/out" || {
    cat "$tmp_root/out" >&2
    fail "$name: failed, but not with \"$want\""
  }
}

# The unmutated copy must pass, or every red result below is meaningless.
reset_tree
VIBE_AST_BINARY_TAGS_ROOT="$tmp_root" bash "$CHECK" > "$tmp_root/green.out" 2>&1 ||
  { cat "$tmp_root/green.out" >&2; fail "unmutated copy of the real tree must pass"; }
grep -q '^\[ast-binary-tags\] ok$' "$tmp_root/green.out" || fail "unmutated copy printed no ok line"

# 1. A declared variant loses its row.
reset_tree
grep -q 'ESpread(Expr)' "$tmp_root/$DOC_REL" || fail "case 1: ESpread row not present to delete"
grep -v '`ESpread(Expr)`' "$tmp_root/$DOC_REL" > "$tmp_root/t" && mv "$tmp_root/t" "$tmp_root/$DOC_REL"
grep -q 'ESpread(Expr)' "$tmp_root/$DOC_REL" && fail "case 1: mutation did not land"
assert_red "case 1 (missing row)" 'has no row: ESpread(Expr)'

# 2. A row names a variant that does not exist.
reset_tree
awk '{ print } /^\| 0x21 \| `EUnit`/ { print "| 0x22 | `EArrayBuilder(Expr)` | `Expr(value)` |" }' \
  "$tmp_root/$DOC_REL" > "$tmp_root/t" && mv "$tmp_root/t" "$tmp_root/$DOC_REL"
grep -q 'EArrayBuilder' "$tmp_root/$DOC_REL" || fail "case 2: mutation did not land"
assert_red "case 2 (phantom row)" 'row names no declared variant: EArrayBuilder(Expr)'

# 3. Two rows share a tag.
reset_tree
grep -q '^| 0x02 | `TyApp' "$tmp_root/$DOC_REL" || fail "case 3: TyApp row not present to renumber"
sed 's@^| 0x02 | `TyApp@| 0x01 | `TyApp@' "$tmp_root/$DOC_REL" > "$tmp_root/t" && mv "$tmp_root/t" "$tmp_root/$DOC_REL"
grep -q '^| 0x01 | `TyApp' "$tmp_root/$DOC_REL" || fail "case 3: mutation did not land"
assert_red "case 3 (duplicate tag)" 'TypeExpr has a duplicate tag 0x01'

# 4. The heading's variant count is wrong -- the mistake that actually
#    happened: a note recorded 27 Stmt variants when the enum has 26.
reset_tree
grep -q '^### Stmt tags (26 variants)$' "$tmp_root/$DOC_REL" || fail "case 4: Stmt heading not in expected form"
sed 's|^### Stmt tags (26 variants)$|### Stmt tags (27 variants)|' "$tmp_root/$DOC_REL" > "$tmp_root/t" &&
  mv "$tmp_root/t" "$tmp_root/$DOC_REL"
grep -q '^### Stmt tags (27 variants)$' "$tmp_root/$DOC_REL" || fail "case 4: mutation did not land"
assert_red "case 4 (wrong heading count)" 'Stmt heading says 27 variants'

# 5. The AST gains a variant and the doc is not updated -- the drift this
#    gate exists for, driven from the SOURCE side rather than the doc side.
reset_tree
grep -q '^  TyUnit$' "$tmp_root/$VPKG_REL" || fail "case 5: TyUnit not in expected form"
sed 's|^  TyUnit$|  TyUnit;\
  TyHole(String)|' "$tmp_root/$VPKG_REL" > "$tmp_root/t" && mv "$tmp_root/t" "$tmp_root/$VPKG_REL"
grep -q 'TyHole(String)' "$tmp_root/$VPKG_REL" || fail "case 5: mutation did not land"
assert_red "case 5 (undocumented new variant)" 'TypeExpr heading says 5 variants'

# 6. A whole section disappears.
reset_tree
grep -q '^### Pat tags' "$tmp_root/$DOC_REL" || fail "case 6: Pat section not present to delete"
sed '/^### Pat tags (10 variants)$/d' "$tmp_root/$DOC_REL" > "$tmp_root/t" &&
  mv "$tmp_root/t" "$tmp_root/$DOC_REL"
if grep -q '^### Pat tags' "$tmp_root/$DOC_REL"; then fail "case 6: mutation did not land"; fi
assert_red "case 6 (missing section)" "no '### Pat tags' section"

# 7. Missing input files are a failure, not a silent pass.
reset_tree
rm -f "$tmp_root/$DOC_REL"
assert_red "case 7 (missing doc)" 'FAIL: missing'

echo "check_ast_binary_tags self-test: ok"
