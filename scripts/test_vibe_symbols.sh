#!/usr/bin/env bash
# Regression test for `vibe symbols` (LSP document-outline / go-to-definition
# foundation; see docs/editor-and-debugging.md). symbol_spans walks the parsed AST
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

pass=0; fail=0
ok()   { echo "ok: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# 0. #1944 leftover: `vibe symbols --legend` is launcher-only (no wasm).
#    Pin the versioned KIND table (v2 / 2026-09-12, #2632) against the source
#    launcher so a missing/wrong table fails in <1s without install.sh.
#    One `KIND NAME` per line, no decoration, never empty.
LAUNCHER="$ROOT_DIR/runtime/vibe"
legend="$(bash "$LAUNCHER" symbols --legend)"
expected=$'2 Module\n6 Method\n10 Enum\n11 Interface\n12 Function\n13 Variable\n23 Struct\n24 Event\n26 TypeParameter\n27 Test\n28 Bench'
if [ "$legend" = "$expected" ]; then
  ok "symbols --legend prints KIND NAME table"
else
  bad "symbols --legend mismatch; got: $legend"
fi

help_out="$(bash "$LAUNCHER" symbols --help 2>&1 || true)"
h_out="$(bash "$LAUNCHER" symbols -h 2>&1 || true)"
if printf '%s\n' "$help_out" | grep -q -- '--legend' \
   && printf '%s\n' "$h_out" | grep -q -- '--legend'; then
  ok "symbols --help/-h point at --legend"
else
  bad "symbols --help/-h should mention --legend; got: $help_out / $h_out"
fi

bash install/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

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

# 7. #1944: test / bench / impl are outlined (Test 27 / Bench 28 since #2632 --
#    a block label is not a declaration -- / Method 6 named after the impl
#    target).
tb="$WORK/testbench.vibe"
printf 'fn add(a: Int, b: Int) -> Int { a + b }\ntest "adds" { let _ = add(1, 2) }\nbench "once" { let _ = add(1, 1) }\ntrait Show { }\nstruct Point { x: Int }\nimpl Show for Point { }\n' > "$tb"
out_tb="$("$VIBE" symbols "$tb" 2>/dev/null || true)"
if has_sym "$out_tb" add 12 && has_sym "$out_tb" adds 27 && has_sym "$out_tb" once 28 \
   && has_sym "$out_tb" Show 11 && has_sym "$out_tb" Point 23 && has_sym "$out_tb" Point 6; then
  ok "symbols lists fn/test/bench/impl with correct kinds"
else
  bad "symbols should find add/adds/once/Show/Point+impl; got: $out_tb"
fi

# 7b. #2632: a block label and a declaration of the same spelling are told
#     apart by KIND, and a declaration's span is the token that spells it --
#     never a copy of the name inside a comment (the #2626 counterexample:
#     `String::length` is at byte 30, after the comment; the comment's copy at
#     14..28 used to win).
lb="$WORK/label_vs_decl.vibe"
printf 'fn not() -> Bool { true }\ntest "not" { let _ = 1 }\n' > "$lb"
out_lb="$("$VIBE" symbols "$lb" 2>/dev/null || true)"
if has_sym "$out_lb" not 12 && has_sym "$out_lb" not 27; then
  ok "symbols tells a test label from a declaration by kind"
else
  bad "symbols should report not 12 and not 27; got: $out_lb"
fi
cm2="$WORK/comment_copy.vibe"
printf 'export fn // "String::length"\nString::length(s: String) -> Int {\n  0 - 1\n}\n' > "$cm2"
out_cm2="$("$VIBE" symbols "$cm2" 2>/dev/null || true)"
if [ "$out_cm2" = "String::length 12 30 44" ]; then
  ok "symbols locates a name at its token, not at a copy inside a comment"
else
  bad "symbols should report [String::length 12 30 44]; got: $out_cm2"
fi

# 7c. Codex on #2708: a raw-string label `r"name"` starts its span at the name,
#     not at the opening quote (the TString token starts at the `r`).
rl="$WORK/raw_label.vibe"
printf 'test r"adds" { let _ = 1 }\n' > "$rl"
out_rl="$("$VIBE" symbols "$rl" 2>/dev/null || true)"
if [ "$out_rl" = "adds 27 7 11" ]; then
  ok "symbols starts a raw-string label at the name"
else
  bad "symbols should report [adds 27 7 11] for a raw-string label; got: $out_rl"
fi

# 7d. Codex on #2718: a `#|` label continued on a second physical line. The
#     lexer joins the lines as "one\ntwo" and drops the indentation and the
#     continuation `#|`, so no interval holds the content and nothing else --
#     7..21 would read `one\n     #|two`. The literal token (5..21) is
#     reported instead, and the newline in the NAME is escaped so the record
#     stays on ONE line (it used to print as two).
ml="$WORK/multiline_label.vibe"
printf 'test #|one\n     #|two\n{ let _ = 1 }\n' > "$ml"
out_ml="$("$VIBE" symbols "$ml" 2>/dev/null || true)"
if [ "$out_ml" = 'one\ntwo 27 5 21' ]; then
  ok "symbols keeps a multi-line #| label on one row, spanning the literal"
else
  bad "symbols should report [one\\ntwo 27 5 21] for a multi-line label; got: $out_ml"
fi

# --- #2381: arguments are no longer accepted and ignored --------------------
# Every case below used to print a.vibe's outline and exit 0, so a caller who
# believed they had asked about two files -- or who typo'd a flag -- got a
# confident, complete-looking answer to a different question.
a1="$WORK/args_a.vibe"; printf 'export let alpha = 1\n' > "$a1"
a2="$WORK/args_b.vibe"; printf 'export let beta = 1\n'  > "$a2"

if out_bad="$("$VIBE" symbols "$a1" --bogus-flag 2>&1)"; then
  bad "symbols must refuse an unknown flag; it exited 0 with: $out_bad"
else
  case "$out_bad" in
    *"unknown flag: --bogus-flag"*) ok "symbols refuses an unknown flag" ;;
    *) bad "symbols refused, but not about the flag: $out_bad" ;;
  esac
fi

if out_missing="$("$VIBE" symbols "$a1" /nonexistent/path.vibe 2>&1)"; then
  bad "symbols must refuse a path that does not exist; it exited 0 with: $out_missing"
else
  case "$out_missing" in
    *"not found: /nonexistent/path.vibe"*) ok "symbols refuses a path that does not exist" ;;
    *) bad "symbols refused, but not about the missing path: $out_missing" ;;
  esac
fi

# --- #2381: batch mode ------------------------------------------------------
# Two paths answer about BOTH, and every line names the file it came from.
out_two="$("$VIBE" symbols "$a1" "$a2")"
if printf '%s\n' "$out_two" | grep -qE "^$a1 alpha 13 [0-9]+ [0-9]+$" \
   && printf '%s\n' "$out_two" | grep -qE "^$a2 beta 13 [0-9]+ [0-9]+$"; then
  ok "symbols over two files answers about both, PATH-prefixed"
else
  bad "symbols over two files should report alpha and beta with paths; got: $out_two"
fi

# A directory is swept recursively, and a non-source file in it is not read.
bd="$WORK/batchdir"; mkdir -p "$bd/sub"
printf 'export let top = 1\n'          > "$bd/top.vibe"
printf 'export let nested = 1\n'       > "$bd/sub/nested.vibe"
printf 'export let ghost = 1\n'        > "$bd/notes.txt"
out_dir="$("$VIBE" symbols "$bd")"
if printf '%s\n' "$out_dir" | grep -qE "^$bd/top.vibe top 13 " \
   && printf '%s\n' "$out_dir" | grep -qE "^$bd/sub/nested.vibe nested 13 " \
   && ! printf '%s\n' "$out_dir" | grep -q 'ghost'; then
  ok "symbols over a directory descends and reads only source files"
else
  bad "symbols over a directory should find top and nested but not ghost; got: $out_dir"
fi

# The field order must not depend on how many files matched: --with-path forces
# the PATH column on for a caller whose computed list happens to hold one entry.
out_one="$("$VIBE" symbols --with-path "$a1")"
if printf '%s\n' "$out_one" | grep -qE "^$a1 alpha 13 [0-9]+ [0-9]+$"; then
  ok "symbols --with-path prefixes a single file too"
else
  bad "symbols --with-path should prefix the path; got: $out_one"
fi

# ... and one bare path still emits exactly the four fields it always did.
out_plain="$("$VIBE" symbols "$a1")"
if printf '%s\n' "$out_plain" | grep -qE '^alpha 13 [0-9]+ [0-9]+$'; then
  ok "symbols on one named file keeps the un-prefixed format"
else
  bad "symbols on one file should stay NAME KIND START END; got: $out_plain"
fi

# --- #2381: a failure is reported AND says so in the exit code --------------
# The unparseable file sorts first, so a sweep that aborted on it would return
# nothing; one that dropped it silently would be a partial inventory reading as
# a complete one. Both halves are asserted: the good rows AND the named failure.
pd="$WORK/partialdir"; mkdir -p "$pd"
printf 'export fn broken( {\n'  > "$pd/a_broken.vibe"
printf 'export let kept = 1\n' > "$pd/b_good.vibe"
p_out="$WORK/partial.out"; p_err="$WORK/partial.err"
if "$VIBE" symbols "$pd" >"$p_out" 2>"$p_err"; then
  bad "symbols must exit non-zero when a file could not be read"
else
  if grep -qE "^$pd/b_good.vibe kept 13 " "$p_out" \
     && grep -q "a_broken.vibe" "$p_err"; then
    ok "symbols reports the readable rows, names the unreadable file, and exits non-zero"
  else
    bad "symbols partial sweep: out=[$(cat "$p_out")] err=[$(cat "$p_err")]"
  fi
fi

# The single-file lane says it failed in the exit code too (it used to print
# the error on stderr and exit 0).
if "$VIBE" symbols "$pd/a_broken.vibe" >/dev/null 2>&1; then
  bad "symbols on an unparseable file must exit non-zero"
else
  ok "symbols on an unparseable file exits non-zero"
fi

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
