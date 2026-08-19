#!/usr/bin/env bash
# Smoke test for selfhost `vibe fmt` (scripts/vibe_fmt.sh): formatting a messy
# file yields the canonical layout, the result is idempotent, and --check
# distinguishes formatted from unformatted.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_fmt_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

printf 'let   add=(a:Int,b:Int)->Int{a+b}\nlet classify=(n:Int)->Int{\nmatch n{0=>1,_=>2}\n}\n' \
  > "$WORK/messy.vibe"

cat > "$WORK/expected.vibe" <<'EOF'
let add = (a: Int, b: Int) -> Int {
  a + b
}
let classify = (n: Int) -> Int {
  match n {
    0 => 1,
    _ => 2
  }
}
EOF

bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/messy.vibe" > "$WORK/got.vibe" 2>/dev/null
if ! cmp -s "$WORK/expected.vibe" "$WORK/got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: canonical layout mismatch" >&2
  diff "$WORK/expected.vibe" "$WORK/got.vibe" >&2 || true
  exit 1
fi

# Idempotency: format(format(x)) == format(x).
cp "$WORK/got.vibe" "$WORK/got_in.vibe"
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/got_in.vibe" > "$WORK/got2.vibe" 2>/dev/null
if ! cmp -s "$WORK/got.vibe" "$WORK/got2.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: not idempotent" >&2; exit 1
fi

# --check: nonzero on messy, zero on already-formatted.
if bash "$ROOT_DIR/scripts/vibe_fmt.sh" --check "$WORK/messy.vibe" >/dev/null 2>&1; then
  echo "[vibe-fmt-smoke] FAIL: --check passed an unformatted file" >&2; exit 1
fi
cp "$WORK/got.vibe" "$WORK/formatted.vibe"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" --check "$WORK/formatted.vibe" >/dev/null 2>&1; then
  echo "[vibe-fmt-smoke] FAIL: --check rejected a formatted file" >&2; exit 1
fi

# #628: import/export paths are a single token — no spaces around `/` or `.`,
# regardless of input spacing. Old fmt tokenized `/` as an operator and emitted
# `./a / b / index.vibe`.
cat > "$WORK/paths.in.vibe" <<'EOF'
import ./pkg/sub/index.vibe { a }
import .. / .. / core.vibe { b }
export ./lib/index.vibe { a, b }
EOF
cat > "$WORK/paths.expected.vibe" <<'EOF'
import ./pkg/sub/index.vibe {
  a
}
import ../../core.vibe {
  b
}
export ./lib/index.vibe {
  a, b
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/paths.in.vibe" > "$WORK/paths.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/paths.expected.vibe" "$WORK/paths.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: import/export path spacing (#628)" >&2
  diff "$WORK/paths.expected.vibe" "$WORK/paths.got.vibe" >&2 || true
  exit 1
fi

# Import-list items are sorted alphabetically (byte/codepoint order, so
# uppercase sorts before lowercase) -- EXCEPT `type X` items, which sort as
# their own group ahead of everything else regardless of their name's case
# (not just cosmetic: lib/@vibe/concurrent/suspend_test.vibe hit a real
# type-checker regression from a same-named type+namespace import pair
# getting reordered relative to each other by a plain alphabetical sort).
cat > "$WORK/sort.in.vibe" <<'EOF'
import @vibe/builtin { zeta_fn, alpha_fn, Middle::Thing, gamma_fn as g, type Beta }
EOF
cat > "$WORK/sort.expected.vibe" <<'EOF'
import @vibe/builtin {
  type Beta, Middle::Thing, alpha_fn, gamma_fn as g, zeta_fn
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/sort.in.vibe" > "$WORK/sort.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/sort.expected.vibe" "$WORK/sort.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: import-list items not sorted alphabetically" >&2
  diff "$WORK/sort.expected.vibe" "$WORK/sort.got.vibe" >&2 || true
  exit 1
fi

# An import-list line that would exceed 140 columns joined on one line wraps
# to one item per line instead.
cat > "$WORK/wrap.in.vibe" <<'EOF'
import @vibe/some/very/long/module/path/that/is/quite/deep { alpha_symbol_one, beta_symbol_two, gamma_symbol_three, delta_symbol_four, epsilon_symbol_five, zeta_symbol_six, eta_symbol_seven, theta_symbol_eight }
EOF
cat > "$WORK/wrap.expected.vibe" <<'EOF'
import @vibe/some/very/long/module/path/that/is/quite/deep {
  alpha_symbol_one,
  beta_symbol_two,
  delta_symbol_four,
  epsilon_symbol_five,
  eta_symbol_seven,
  gamma_symbol_three,
  theta_symbol_eight,
  zeta_symbol_six
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/wrap.in.vibe" > "$WORK/wrap.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/wrap.expected.vibe" "$WORK/wrap.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: long import-list did not wrap to one item per line" >&2
  diff "$WORK/wrap.expected.vibe" "$WORK/wrap.got.vibe" >&2 || true
  exit 1
fi

# A struct literal immediately after `export let x = ... -> Name { .. }` must
# NOT be mistaken for an import-list brace just because it follows a NAME
# token in a statement whose head keyword was `export` -- must stay a plain
# one-field-per-line block (c_brace_block), not the import-list wrap layout.
cat > "$WORK/not_import.in.vibe" <<'EOF'
export let make: () -> Foo = () -> Foo { field: 1 }
EOF
cat > "$WORK/not_import.expected.vibe" <<'EOF'
export let make: () -> Foo = () -> Foo {
  field: 1
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/not_import.in.vibe" > "$WORK/not_import.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/not_import.expected.vibe" "$WORK/not_import.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: struct literal after 'export let ... -> Name' misdetected as import list" >&2
  diff "$WORK/not_import.expected.vibe" "$WORK/not_import.got.vibe" >&2 || true
  exit 1
fi

# `export enum Re { A; B; C }` / `export struct Foo { field: Map[K, V] }`
# bodies must NOT be misdetected as an import list either: walking backward
# from `{` through `Re`/`Foo` then hitting the `enum`/`struct` keyword must
# stop the scan (two name/keyword segments in a row with no `.`/`/`/`::`
# separator is never valid import-path syntax), not skip through it to reach
# `export` further back and wrongly sort/reflow the body as an import list.
cat > "$WORK/enum_not_import.in.vibe" <<'EOF'
export enum Re {
  RChar(Int)
  RDot
  RSeq(Array[Re])
}
export struct Foo {
  entries: Map[String, Bool]
}
EOF
cat > "$WORK/enum_not_import.expected.vibe" <<'EOF'
export enum Re {
  RChar(Int)
  RDot
  RSeq(Array[Re])
}
export struct Foo {
  entries: Map[String, Bool]
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/enum_not_import.in.vibe" > "$WORK/enum_not_import.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/enum_not_import.expected.vibe" "$WORK/enum_not_import.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: export enum/struct body misdetected as import list" >&2
  diff "$WORK/enum_not_import.expected.vibe" "$WORK/enum_not_import.got.vibe" >&2 || true
  exit 1
fi

# A brace BLOCK (one statement per source line) nested inside an enclosing
# call's parens -- e.g. a multi-statement closure passed as a call argument,
# `run(() -> { .. })` -- must keep each statement on its own line. The raw
# newline-preservation pass used to swallow every newline once ANY enclosing
# paren was open (absolute paren_depth > 0), collapsing the whole closure
# body onto one line; it must only swallow newlines from parens opened
# *after* the innermost currently-open block.
cat > "$WORK/nested_call_block.in.vibe" <<'EOF'
fn foo() -> Int {
  let r = run(() -> {
    let t = 5
    let a = t
    let b = t
    a
  })
  1
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/nested_call_block.in.vibe" > "$WORK/nested_call_block.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/nested_call_block.in.vibe" "$WORK/nested_call_block.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: statement newlines collapsed inside a call-argument closure body" >&2
  diff "$WORK/nested_call_block.in.vibe" "$WORK/nested_call_block.got.vibe" >&2 || true
  exit 1
fi

# `from` is not a keyword in the real grammar (lib/@vibe/parser has no
# k_from/"from" handling) -- it's a perfectly valid bare identifier, e.g. a
# parameter name. The formatter's own lexer still tags it k_from (vestigial),
# so a brace directly preceded by a bare `from` (not part of any real import
# statement) must NOT be misdetected as an import list: `if name == from {
# ELetRec(name, v, b) }` corrupted into `ELetRec(name, b), v` when
# reorder_import_lists's nesting-blind comma split ran over the misdetected
# brace's contents, splitting and re-sorting a nested call's own arguments.
cat > "$WORK/from_ident.in.vibe" <<'EOF'
fn dlh_subst(expr: Expr, from: String, to: String) -> Expr {
  if name == from {
    ELetRec(name, v, b)
  }
  1
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/from_ident.in.vibe" > "$WORK/from_ident.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/from_ident.in.vibe" "$WORK/from_ident.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: bare 'from' identifier before '{' misdetected as import list" >&2
  diff "$WORK/from_ident.in.vibe" "$WORK/from_ident.got.vibe" >&2 || true
  exit 1
fi

# `x is CtUnknown {` (a bare-variant pattern check via `is`) must NOT get a
# struct-literal `::` inserted before the `{` -- that `{` opens the enclosing
# `if`'s body, unrelated to the `is` check. Confirmed real corruption:
# checker.vibe's `if hres_now is CtUnknown {` became `if hres_now is
# CtUnknown::{`, which parses the block body as bogus struct-literal fields
# and cascades into an unrelated "unexpected token" error much later in the
# file (the merge-flatten compile step of scripts/generate_bundle.sh).
cat > "$WORK/is_ctor.in.vibe" <<'EOF'
fn foo(x: Type) -> Int {
  if x is CtUnknown {
    1
  } else {
    2
  }
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/is_ctor.in.vibe" > "$WORK/is_ctor.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/is_ctor.in.vibe" "$WORK/is_ctor.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: 'x is CapitalizedVariant {' got a spurious struct-literal '::' inserted" >&2
  diff "$WORK/is_ctor.in.vibe" "$WORK/is_ctor.got.vibe" >&2 || true
  exit 1
fi

# `k_handle` and `k_return` were missing from is_keyword_kind entirely, so
# needs_space's is_keyword_kind(prev)/is_keyword_kind(curr) checks both fell
# through to false for the specific pair `return` immediately followed by
# `handle` -- no other rule in needs_space covers two adjacent bare keywords
# with no operator/punctuation between them. Confirmed real corruption:
# cli_adapter.vibe's `return handle { .. } with Error { .. }` had the space
# dropped, gluing them into a single `returnhandle` token, which cascaded
# into an unrelated far-later "unexpected token: with" parse error (the
# merge-flatten compile step of scripts/generate_bundle.sh).
cat > "$WORK/return_handle.in.vibe" <<'EOF'
fn foo() -> Int with Exception {
  return handle {
    1
  } with Exception {
    Throw(msg) => 0
  }
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/return_handle.in.vibe" > "$WORK/return_handle.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/return_handle.in.vibe" "$WORK/return_handle.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: 'return handle {' lost its space and glued into 'returnhandle'" >&2
  diff "$WORK/return_handle.in.vibe" "$WORK/return_handle.got.vibe" >&2 || true
  exit 1
fi

# `import <path> as <alias> only { .. }` (#897): the qualified-import suffix
# `as <alias> only` puts two bare-name tokens (`<alias>` then `only`, an
# ordinary k_name to this lexer, not a reserved word) back to back with no
# `.`/`/`/`::` separator between them. Confirmed real regression (Codex
# review on #1193): brace_starts_import_list's adjacent-name-collision guard
# aborted the backward scan at `only`/`<alias>` before ever reaching
# `import`, so this form silently stopped getting sorted/wrapped.
cat > "$WORK/as_only.in.vibe" <<'EOF'
import @vibe/some/pkg as ns only { alpha_symbol_one, beta_symbol_two, gamma_symbol_three, delta_symbol_four, epsilon_symbol_five, zeta_symbol_six, eta_symbol_seven, theta_symbol_eight }
EOF
cat > "$WORK/as_only.expected.vibe" <<'EOF'
import @vibe/some/pkg as ns only {
  alpha_symbol_one,
  beta_symbol_two,
  delta_symbol_four,
  epsilon_symbol_five,
  eta_symbol_seven,
  gamma_symbol_three,
  theta_symbol_eight,
  zeta_symbol_six
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/as_only.in.vibe" > "$WORK/as_only.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/as_only.expected.vibe" "$WORK/as_only.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: 'import <path> as <alias> only { .. }' not sorted/wrapped" >&2
  diff "$WORK/as_only.expected.vibe" "$WORK/as_only.got.vibe" >&2 || true
  exit 1
fi

echo "[vibe-fmt-smoke] ok (canonical + idempotent + --check + paths #628 + import sort/wrap + enum/struct guard + nested-call block newlines + from-identifier guard + is-ctor guard + return-handle guard + as-only guard)"
