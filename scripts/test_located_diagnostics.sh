#!/usr/bin/env bash
# Regression test for located diagnostics (docs/release-roadmap.md source-span):
# `vibe check` reports `line N:col M:` for parse errors and the common type
# errors (unknown name / arity), via the freshly built compiler. Guards the
# located-diagnostic + the `+`-string-concat NUL fix.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

bash scripts/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"

pass=0; fail=0
expect_contains() { # <desc> <needle> <file.vibe content...>
  local desc="$1" needle="$2"; shift 2
  local f="$WORK/case.vibe"
  printf '%b' "$1" > "$f"
  local out; out="$("$VIBE" check "$f" 2>&1 || true)"
  if printf '%s' "$out" | grep -qF "$needle"; then
    echo "ok: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (want '$needle' in: $out)" >&2; fail=$((fail + 1))
  fi
}

expect_matches() { # <desc> <ere> <file.vibe content>
  local desc="$1" ere="$2"; shift 2
  local f="$WORK/case.vibe"
  printf '%b' "$1" > "$f"
  local out; out="$("$VIBE" check "$f" 2>&1 || true)"
  if printf '%s' "$out" | grep -qE "$ere"; then
    echo "ok: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc (want /$ere/ in: $out)" >&2; fail=$((fail + 1))
  fi
}

# parse error on line 2 -> line:col located
expect_contains "parse error located on line 2" "line 2:" \
  'export let a = 1\nexport let bad = = 5\n'

# unknown name -> located with the exact column of the symbol
expect_contains "unknown-name type error located" "line 1:" \
  'export let main = () -> Int { zzz }\n'

# unknown name -> EXACT range form `line N:colM-K:` (the checker now emits the
# token end offset; `zzz` is 3 chars wide). Backward-compatible `line N:` still
# leads, but the `-K` end column must be present for a known-length symbol.
expect_matches "unknown-name carries an exact range (colM-K)" "line 1:[0-9]+-[0-9]+:" \
  'export let main = () -> Int { zzz }\n'

# arity mismatch -> located
expect_contains "arity mismatch located" "function arity mismatch" \
  'let h = (a: Int, b: Int) -> Int { a + b }\nexport let main = () -> Int { h(1) }\n'

# arity mismatch -> located at the CALL site, not the DEFINITION.
# `helper` is defined on line 1 but called with wrong arity on line 4; the
# located diagnostic must point at the call (line 4) via the real AST offset
# threaded through the [@off=N] marker, NOT the first text occurrence (line 1).
expect_contains "arity mismatch located at call site (line 4)" "line 4:" \
  'let helper = (a: Int, b: Int) -> Int { a + b }\nexport let l2 = 0\nexport let l3 = 0\nexport let main = () -> Int { helper(1) }\n'

# method-style call (EDot callee) arity mismatch -> located at the CALL site
# (span-arc step2: the ECall source offset feeds the EDot-callee arity
# diagnostic, which previously emitted off_marker(-1) and could not be located
# precisely). `s.length(99)` calls the 1-arg String::length with 2 args on
# line 6, so the located diagnostic must point at line 6.
expect_contains "method-call arity located at call site (line 6)" "line 6:" \
  'export let l1 = 0\nexport let l2 = 0\nexport let l3 = 0\nexport let main = () -> Int {\n  let s = "hi"\n  s.length(99)\n}\n'

# field access on an unknown struct field (EDot) -> located at the ACCESS site
# (span-arc step2: the EDot source offset, threaded from the base-expression
# start via callee_offset, feeds the checker's unknown-field diagnostic through
# the [@off=N] marker; before this it emitted off_marker(-1) and could not be
# located). `p.z` accesses a non-existent field on Point at line 3, so the
# located diagnostic must point at line 3.
expect_contains "unknown-field access located at access site (line 3)" "line 3:" \
  'struct Point { x: Int; y: Int }\nexport let get = (p: Point) -> Int {\n  p.z\n}\nexport let main = () -> Int { 0 }\n'

# #645: EDot now carries the FIELD token's own offset, so the unknown-field
# diagnostic is an exact compiler-authoritative range over the field name
# (`line 3:col5-6:` for the 1-char `z`), no LSP-side dot-hop word scan.
expect_matches "unknown-field carries an exact field range (colM-K)" "line 3:5-6:" \
  'struct Point { x: Int; y: Int }\nexport let get = (p: Point) -> Int {\n  p.z\n}\nexport let main = () -> Int { 0 }\n'

# #953: method-style call `l.total()` with only a BARE top-level
# `fn total(l: MyList)` in scope used to escape the checker and die in codegen
# with an unlocated "unknown struct field: total". The checker now reports a
# located "no method" diagnostic with an exact range over the method token
# (`total` starts at col 3 on line 10: `  l.total()` -> the field token offset
# feeds the [@off=N:M] marker).
expect_contains "bare-fn dot call reports no-method (#953)" 'no method `total` on `MyList`' \
  'enum MyList { Nil; Cons(Int, MyList) }\nfn total(l: MyList) -> Int {\n  match l {\n    Nil => 0,\n    Cons(h, t) => h + total(t)\n  }\n}\nexport let main = () -> Int {\n  let l = Cons(1, Nil)\n  l.total()\n}\n'
expect_matches "bare-fn dot call no-method located with exact range (#953)" "line 10:5-10:" \
  'enum MyList { Nil; Cons(Int, MyList) }\nfn total(l: MyList) -> Int {\n  match l {\n    Nil => 0,\n    Cons(h, t) => h + total(t)\n  }\n}\nexport let main = () -> Int {\n  let l = Cons(1, Nil)\n  l.total()\n}\n'

# #1567: the type errors that used to arrive with NO location at all. Each
# passed a hardcoded -1 where the offending expression was in scope; the anchor
# is now threaded through. Assert the exact line:col, not just "some location" —
# an anchor on the wrong sub-expression still produces a plausible number.
expect_contains "implicit tail return locates on the returned expr" "line 3:3:" \
  'export let mk = () -> String { "s" }\nexport fn f() -> Int {\n  mk()\n}\n'
expect_contains "explicit return locates on the returned expr" "line 3:10:" \
  'export let mk = () -> String { "s" }\nexport fn f() -> Int {\n  return mk()\n}\n'
# A body that opens with a statement parses as ELet(_, val, REST, _), not ESeq,
# so a tail walk that only knows ESeq drops back to no location here.
expect_contains "tail return past a let statement still locates on the tail" "line 5:3:" \
  'export let setup = () -> Int { 1 }\nexport let mk = () -> String { "s" }\nexport fn f() -> Int {\n  let _ = setup()\n  mk()\n}\n'
# `let x: T = v` desugars to a synthetic call whose own offset is -1; the anchor
# has to come from the bound VALUE.
expect_contains "annotated local let locates on the bound value" "line 3:16:" \
  'export let mk = () -> String { "s" }\nexport fn main() -> Int {\n  let x: Int = mk()\n  0\n}\n'
expect_contains "binop mismatch locates on an operand" "line 3:3:" \
  'export let s = "str"\nexport fn main() -> Int {\n  s & 1\n}\n'

# the internal [@off=N] offset marker must never leak into user-facing output.
expect_missing() { # <desc> <needle-that-must-be-absent> <file.vibe content>
  local desc="$1" needle="$2"; shift 2
  local f="$WORK/case.vibe"
  printf '%b' "$1" > "$f"
  local out; out="$("$VIBE" check "$f" 2>&1 || true)"
  if printf '%s' "$out" | grep -qF "$needle"; then
    echo "FAIL: $desc (unwanted '$needle' in: $out)" >&2; fail=$((fail + 1))
  else
    echo "ok: $desc"; pass=$((pass + 1))
  fi
}
expect_missing "no [@off= marker leak (arity)" "[@off=" \
  'let helper = (a: Int, b: Int) -> Int { a + b }\nexport let l2 = 0\nexport let main = () -> Int { helper(1) }\n'
expect_missing "no [@off= marker leak (unknown name)" "[@off=" \
  'export let a = 1\nexport let main = () -> Int { zzz }\n'
expect_missing "no [@off= marker leak (unknown field)" "[@off=" \
  'struct Point { x: Int; y: Int }\nexport let get = (p: Point) -> Int {\n  p.z\n}\nexport let main = () -> Int { 0 }\n'

# #1567, the flip side of the located type errors above — stated so it reads as
# a decision rather than an accident: an expression built only from LITERALS has
# no offset to anchor on (EInt/EFloat/EString/EBool have no offset slot in
# lib/@vibe/ast/index.vpkg), so it stays unlocated rather than borrowing a
# nearby node's position and confidently pointing at the wrong thing.
expect_missing "literal-only mismatch does not invent a location" "line " \
  'export fn main() -> Int {\n  1 + "s"\n}\n'

# #1567: EXACTLY ONE location per diagnostic, and it must be the crime scene.
#
# A per-module error is rendered `<path>: line N:C: <msg>` and then handed to a
# second, entry-level locate pass. That pass only recognized a message as
# already-located when the location sat at index 0, so the path-prefixed shape
# fell through to the first-occurrence heuristic and got a SECOND location
# glued to its front -- the first textual occurrence of the symbol, i.e. its
# DECLARATION, not the call that is actually wrong:
#
#   error: line 1:12: /tmp/x.vibe: line 3:3-4: function arity mismatch for g
#
# Both numbers are real positions of `g`, so nothing looks broken; the leading
# one is just wrong, and it is the one a reader or an `^line N:C`-parsing LSP
# takes. Pin the count (one `line N:C:`) and the value (line 3, the call).
locdup="$WORK/dup.vibe"
printf 'export let g = (a: Int, b: Int) -> Int { a + b }\nexport fn main() -> Int {\n  g(1)\n}\n' > "$locdup"
dup_out="$("$VIBE" check "$locdup" 2>&1 || true)"
dup_n="$(printf '%s' "$dup_out" | grep -oE 'line [0-9]+:[0-9]+' | wc -l | tr -d ' ')"
if [ "$dup_n" = "1" ]; then
  echo "ok: same-file arity mismatch carries exactly one location"; pass=$((pass + 1))
else
  echo "FAIL: expected 1 location, got $dup_n (in: $dup_out)" >&2; fail=$((fail + 1))
fi
if printf '%s' "$dup_out" | grep -qE 'line 3:3'; then
  echo "ok: the location is the call site, not the declaration"; pass=$((pass + 1))
else
  echo "FAIL: expected the call site (line 3:3) in: $dup_out" >&2; fail=$((fail + 1))
fi

# ...and the guard must not depend on what the PATH contains. `: ` is legal in a
# POSIX path, so a guard anchored on the first `: ` in the message lands inside
# the path and falls back to the buggy behaviour (#1628 review, Codex P2).
locdir="$WORK/foo: bar"
mkdir -p "$locdir"
printf 'export let g = (a: Int, b: Int) -> Int { a + b }\nexport fn main() -> Int {\n  g(1)\n}\n' > "$locdir/dup.vibe"
sep_out="$("$VIBE" check "$locdir/dup.vibe" 2>&1 || true)"
sep_n="$(printf '%s' "$sep_out" | grep -oE 'line [0-9]+:[0-9]+' | wc -l | tr -d ' ')"
if [ "$sep_n" = "1" ]; then
  echo "ok: a path containing ': ' still yields exactly one location"; pass=$((pass + 1))
else
  echo "FAIL: expected 1 location for a ': '-containing path, got $sep_n (in: $sep_out)" >&2; fail=$((fail + 1))
fi

# #1839: an anonymous `record { ... }` literal is CtRecord (structural), so
# passing it where a nominal struct is expected is a LOCATED type mismatch
# whose message prints the record's shape -- it used to typecheck (record
# captured as the struct, then CtUnknown) and read wrong slots at runtime.
expect_contains "record-into-struct-arg rejected with the record's shape (#1839)" \
  "expected Span, got record { start: Int, end: Int }" \
  'struct Span { end: Int; start: Int }\nfn span_width(s: Span) -> Int { s.end - s.start }\nexport fn main() -> Int {\n  span_width(record { start: 3, end: 9 })\n}\n'

expect_contains "record-into-struct-annotation rejected (#1839)" \
  "expected Span, got record { start: Int, end: Int }" \
  'struct Span { end: Int; start: Int }\nexport fn main() -> Int {\n  let r: Span = record { start: 3, end: 9 }\n  r.start\n}\n'

# ...a representation-specific builtin receiver check also rejects a record
# (head_kind gives CtRecord a concrete head instead of the tolerate bucket;
# Codex review on #1867 -- Array::get on a record used to pass and read the
# record layout as an array)...
expect_contains "record rejected as an Array builtin receiver (#1839)" \
  "Array::get" \
  'export fn main() -> Int {\n  Array::get(record { a: 1 }, 0)\n}\n'

# ...while a record used AS a record stays accepted (same colliding struct in
# scope; literal-order dot access).
printf 'struct Span { end: Int; start: Int }\nexport fn main() -> Int {\n  let r = record { start: 3, end: 9 }\n  r.start + r.end\n}\n' > "$WORK/rec_ok.vibe"
if "$VIBE" check "$WORK/rec_ok.vibe" >/dev/null 2>&1; then
  echo "ok: record used structurally checks clean beside a colliding struct"; pass=$((pass + 1))
else
  echo "FAIL: structural record use should check clean (got: $("$VIBE" check "$WORK/rec_ok.vibe" 2>&1 | head -2))" >&2; fail=$((fail + 1))
fi

# a good program -> check passes (no error)
printf 'export let main = () -> Int { 40 + 2 }\n' > "$WORK/ok.vibe"
if "$VIBE" check "$WORK/ok.vibe" >/dev/null 2>&1; then
  echo "ok: good program checks clean"; pass=$((pass + 1))
else
  echo "FAIL: good program should check clean" >&2; fail=$((fail + 1))
fi

echo "[located-diagnostics] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
