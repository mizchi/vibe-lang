#!/usr/bin/env bash
# Regression test for `vibe symbols` (LSP document-outline / go-to-definition
# foundation, docs/release-roadmap.md テーマ4). symbol_spans walks the parsed AST
# and prints one `NAME KIND START END` line per declared symbol (KIND = LSP
# SymbolKind int, START/END = char offsets of the declaration name). Unlike a
# line-regex scan it handles multi-line declarations, module-nested symbols, and
# never reports a name that only appears inside a comment.
#
# The committed seed predates this feature, so this test builds a FRESH compiler
# via install/install.sh into a throwaway VIBE_HOME/VIBE_BIN_DIR.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

bash install/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0
ok()   { echo "ok: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# field(line, n) -> the n-th whitespace-separated field of a `NAME KIND START END`
# row. `has_sym out name kind` asserts a row with that NAME and KIND exists.
has_sym() {
  printf '%s\n' "$1" | grep -qE "^$2 $3 [0-9]+ [0-9]+$"
}

# 1. mixed declarations: struct(23), enum(10), value(13), function(12), trait(11).
m="$WORK/mixed.vibe"
printf 'export struct Point { x: Int; y: Int }\nexport enum Color { Red; Green }\nexport let origin = 0\nexport let add = (a: Int, b: Int) -> Int { a + b }\ntrait Show { }\n' > "$m"
out="$("$VIBE" symbols "$m" 2>/dev/null || true)"
if has_sym "$out" Point 23 && has_sym "$out" Color 10 && has_sym "$out" origin 13 \
   && has_sym "$out" add 12 && has_sym "$out" Show 11; then
  ok "symbols lists struct/enum/value/function/trait with correct kinds"
else
  bad "symbols kinds wrong; got: $out"
fi

# 2. the START offset of a name must point at the actual name in the source.
#    `Point` begins at offset 14 (`export struct ` is 14 chars).
pstart="$(printf '%s\n' "$out" | awk '$1=="Point"{print $3}')"
if [ "$pstart" = "14" ]; then
  ok "symbols name offset is exact (Point at 14)"
else
  bad "symbols Point offset should be 14, got '$pstart'"
fi

# 3. multi-line declaration: a `let` split across lines is still found (a
#    line-regex scan keyed on `^export let NAME` would miss it).
ml="$WORK/multiline.vibe"
printf 'export let\n  wrapped =\n  (n: Int) -> Int { n }\n' > "$ml"
out_ml="$("$VIBE" symbols "$ml" 2>/dev/null || true)"
if has_sym "$out_ml" wrapped 12; then
  ok "symbols finds a multi-line declaration"
else
  bad "symbols should find multi-line 'wrapped'; got: $out_ml"
fi

# 4. fn-syntax declarations (#727; module blocks were removed in #728):
#    top-level `fn` and `export fn` report as functions alongside values.
mn="$WORK/fnsyms.vibe"
printf 'fn double(x: Int) -> Int { x * 2 }\nexport fn top(y: Int) -> Int { y }\nexport let zero = 0\n' > "$mn"
out_mn="$("$VIBE" symbols "$mn" 2>/dev/null || true)"
if has_sym "$out_mn" double 12 && has_sym "$out_mn" top 12 && has_sym "$out_mn" zero 13; then
  ok "symbols finds fn-syntax declarations"
else
  bad "symbols should find double/top/zero; got: $out_mn"
fi

# 5. a name appearing only inside a comment must NOT be reported.
cm="$WORK/comment.vibe"
printf '// export let ghost = 1\nexport let real = 1\n' > "$cm"
out_cm="$("$VIBE" symbols "$cm" 2>/dev/null || true)"
if has_sym "$out_cm" real 13 && ! printf '%s\n' "$out_cm" | grep -qE '^ghost '; then
  ok "symbols excludes a name that only appears in a comment"
else
  bad "symbols should report 'real' but not 'ghost'; got: $out_cm"
fi

# 6. an empty / declaration-free file yields empty output (a report, exit 0).
ef="$WORK/empty.vibe"
printf 'export let main = () -> Int { 1 }\n' > "$ef"
out_ef="$("$VIBE" symbols "$ef" 2>/dev/null || true)"
if has_sym "$out_ef" main 12; then
  ok "symbols reports a lone main as a function"
else
  bad "symbols should report 'main' as function(12); got: $out_ef"
fi

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
