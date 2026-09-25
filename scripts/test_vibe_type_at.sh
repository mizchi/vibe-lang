#!/usr/bin/env bash
# Regression test for `vibe type-at` (LSP typed-hover MVP, docs/internal/project/release-roadmap.md
# テーマ4). type_at_source locates the identifier at a 1-based (line, col) via the
# real EIdent / binding-name source offsets, typechecks the program, and prints
# the inferred type of that name. A binder answers at its declaration too
# (#3000). Hovering whitespace / a keyword (no identifier there) prints nothing
# on stdout, names the position on stderr and exits 1.
#
# The committed seed predates this feature, so this test builds a FRESH compiler
# via install/install.sh (default, no --cli-wasm seed override) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR so it never touches a real install.
#
# TYPE_AT_CLI_WASM=<stage2.wasm> skips the install and asks that compiler
# through runtime/vibe on the node runner -- the way to test a compiler change
# before it is installed. A named artifact that does not exist is an error.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

if [ -n "${TYPE_AT_CLI_WASM:-}" ]; then
  [ -s "$TYPE_AT_CLI_WASM" ] || { echo "FAIL: TYPE_AT_CLI_WASM does not exist: $TYPE_AT_CLI_WASM" >&2; exit 1; }
  VIBE="$WORK/vibe"
  cat > "$VIBE" <<SH
#!/usr/bin/env bash
exec env VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_PREOPEN_DIR=/ VIBE_CLI_WASM="$TYPE_AT_CLI_WASM" bash "$ROOT_DIR/runtime/vibe" "\$@"
SH
  chmod +x "$VIBE"
else
  # Fresh compiler (NOT the seed): the seed cannot answer type-at queries.
  bash install/install.sh >/dev/null 2>&1
  VIBE="$VIBE_BIN_DIR/vibe"
  [ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }
fi

pass=0; fail=0

# `add` starts at char offset 11 (`export let ` is 11 chars), which is 1-based
# column 12 (offset_to_line_col: offset 11 -> col 12). So `type-at f 1 12` lands
# on the `add` identifier and must yield its function type (a type over Int).
f="$WORK/add.vibe"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$f"

ty_add="$("$VIBE" type-at "$f" 1 12 2>/dev/null || true)"
if printf '%s' "$ty_add" | grep -qF "Int"; then
  echo "ok: type-at on 'add' (1:12) contains Int -> '$ty_add'"; pass=$((pass + 1))
else
  echo "FAIL: type-at on 'add' (1:12) should contain Int, got '$ty_add'" >&2; fail=$((fail + 1))
fi

# Hovering a non-identifier is an ERROR (#3000): empty stdout, a stderr line
# naming the position, exit 1 -- so that empty stdout with exit 0 means only
# "an identifier with no known type". Column 7 is the space between `export`
# and `let`, column 1 the keyword `export`, line 9 is past the end of the file.
no_ident() { # no_ident <file> <line> <col> <label>
  local out rc=0
  out="$("$VIBE" type-at "$1" "$2" "$3" 2>"$WORK/no_ident.err")" || rc=$?
  if [ -z "$out" ] && [ "$rc" -ne 0 ] && grep -qF "no identifier at" "$WORK/no_ident.err"; then
    echo "ok: type-at on $4 ($2:$3) reports no identifier and exits $rc"; pass=$((pass + 1))
  else
    echo "FAIL: type-at on $4 ($2:$3) should print nothing, exit non-zero and say 'no identifier at' on stderr; got stdout '$out', exit $rc, stderr '$(cat "$WORK/no_ident.err")'" >&2; fail=$((fail + 1))
  fi
}
no_ident "$f" 1 7 "whitespace"
no_ident "$f" 1 1 "a keyword"
no_ident "$f" 9 1 "a line past the end of the file"

# A file that does not parse has no types at all; it used to answer nothing
# with exit 0, which read like a clean miss.
bad="$WORK/bad.vibe"
printf 'struct P { x: Int, y: String }\nfn f(p: P) -> Int {\n  p.x\n}\n' > "$bad"
rc_bad=0
ty_bad="$("$VIBE" type-at "$bad" 3 3 2>"$WORK/bad.err")" || rc_bad=$?
if [ -z "$ty_bad" ] && [ "$rc_bad" -ne 0 ] && grep -qF "does not parse" "$WORK/bad.err"; then
  echo "ok: type-at on a file that does not parse says so and exits $rc_bad"; pass=$((pass + 1))
else
  echo "FAIL: type-at on a file that does not parse: want empty stdout, non-zero exit, 'does not parse' on stderr; got '$ty_bad', exit $rc_bad, stderr '$(cat "$WORK/bad.err")'" >&2; fail=$((fail + 1))
fi

# An identifier with NO known type (an unused pattern binder) is the one
# meaning left for empty stdout: exit 0, and stderr names the identifier.
u="$WORK/unused.vibe"
printf 'fn f(o: Option[Int]) -> Int {\n  match o {\n    Some(v) => 0\n    None => 1\n  }\n}\n' > "$u"
rc_u=0
ty_u="$("$VIBE" type-at "$u" 3 10 2>"$WORK/unused.err")" || rc_u=$?
if [ -z "$ty_u" ] && [ "$rc_u" -eq 0 ] && grep -qF 'no type is known for `v`' "$WORK/unused.err"; then
  echo "ok: type-at on an unused binder (3:10) is empty, exit 0, and names it on stderr"; pass=$((pass + 1))
else
  echo "FAIL: type-at on an unused binder (3:10): want empty stdout, exit 0, stderr naming \`v\`; got '$ty_u', exit $rc_u, stderr '$(cat "$WORK/unused.err")'" >&2; fail=$((fail + 1))
fi

# Hovering a USE of an env-visible name resolves too (line 2 references `add`).
g="$WORK/use.vibe"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\nexport let main = () -> Int { add(1, 2) }\n' > "$g"
ty_use="$("$VIBE" type-at "$g" 2 31 2>/dev/null || true)"
if printf '%s' "$ty_use" | grep -qF "Int"; then
  echo "ok: type-at on a use of 'add' (2:31) contains Int -> '$ty_use'"; pass=$((pass + 1))
else
  echo "FAIL: type-at on a use of 'add' (2:31) should contain Int, got '$ty_use'" >&2; fail=$((fail + 1))
fi

# LOCALS and PARAMETERS resolve via the per-node type table (they live in nested
# inference scopes, gone from the returned TypeEnv, so the env-lookup fallback
# alone would yield ""). File: `export let f = (n: Int) -> Int { let g = n * 2`
# / `  g }`.  The USE of the parameter `n` in `n * 2` is line 1 col 42; the USE
# of the local `g` returned on line 2 col 3. Both must resolve to Int.
h="$WORK/local.vibe"
printf 'export let f = (n: Int) -> Int { let g = n * 2\n  g }\n' > "$h"

ty_param="$("$VIBE" type-at "$h" 1 42 2>/dev/null || true)"
if printf '%s' "$ty_param" | grep -qF "Int"; then
  echo "ok: type-at on parameter use 'n' (1:42) contains Int -> '$ty_param'"; pass=$((pass + 1))
else
  echo "FAIL: type-at on parameter use 'n' (1:42) should contain Int, got '$ty_param'" >&2; fail=$((fail + 1))
fi

ty_local="$("$VIBE" type-at "$h" 2 3 2>/dev/null || true)"
if printf '%s' "$ty_local" | grep -qF "Int"; then
  echo "ok: type-at on local use 'g' (2:3) contains Int -> '$ty_local'"; pass=$((pass + 1))
else
  echo "FAIL: type-at on local use 'g' (2:3) should contain Int, got '$ty_local'" >&2; fail=$((fail + 1))
fi

# CALL-SITE hover (span-arc step4): the per-node type table now records the
# RESULT type of a call keyed by the call's source offset (the callee start).
# `is_pos` returns Bool while its argument is Int, so hovering the CALL `is_pos(5)`
# must resolve to the RESULT type Bool (not the Int argument, not the function
# type). File:
#   export let is_pos = (n: Int) -> Bool { n > 0 }
#   export let main = () -> Bool { is_pos(5) }
# `export let main = () -> Bool { ` is 31 chars, so the call `is_pos(5)` starts
# at line 2 col 32; the recorded result type there must be Bool.
k="$WORK/call.vibe"
printf 'export let is_pos = (n: Int) -> Bool { n > 0 }\nexport let main = () -> Bool { is_pos(5) }\n' > "$k"

ty_call="$("$VIBE" type-at "$k" 2 32 2>/dev/null || true)"
if printf '%s' "$ty_call" | grep -qF "Bool"; then
  echo "ok: type-at on call site 'is_pos(5)' (2:32) resolves to result Bool -> '$ty_call'"; pass=$((pass + 1))
else
  echo "FAIL: type-at on call site 'is_pos(5)' (2:32) should resolve to Bool, got '$ty_call'" >&2; fail=$((fail + 1))
fi

# FIELD-ACCESS hover (span-arc step4): the per-node type table now records a
# field projection's type keyed by the EDot source offset (the base-expr start).
# `p.x` projects field `x: Int` of a struct-typed parameter `p`, so hovering the
# access must resolve to the FIELD type Int (the EDot record runs after the base
# EIdent record at the same offset, so it wins). File:
#   export struct P { x: Int }
#   export let getx = (p: P) -> Int { p.x }
# `export let getx = (p: P) -> Int { ` is 34 chars, so `p.x` base `p` is at
# line 2 col 35.
m="$WORK/field.vibe"
printf 'export struct P { x: Int }\nexport let getx = (p: P) -> Int { p.x }\n' > "$m"

ty_field="$("$VIBE" type-at "$m" 2 35 2>/dev/null || true)"
if printf '%s' "$ty_field" | grep -qF "Int"; then
  echo "ok: type-at on field access 'p.x' (2:35) resolves to field Int -> '$ty_field'"; pass=$((pass + 1))
else
  echo "FAIL: type-at on field access 'p.x' (2:35) should resolve to Int, got '$ty_field'" >&2; fail=$((fail + 1))
fi

# BINDER DECLARATION SITES (#3000): each form answers where the name is
# introduced, with the type its uses have. Columns are 1-based BYTE columns.
b="$WORK/binders.vibe"
cat > "$b" <<'VIBE'
effect Log {
  Emit(String) -> Unit
}
fn run(sink: Array[String]) -> Unit {
  handle {
    perform Log::Emit("hi")
  } with { Log::Emit(msg) => {
    Array::push(sink, msg)
    resume(())
  } }
}
fn m(o: Option[Int]) -> Int {
  match o {
    Some(v) => v
    None => 0
  }
}
fn d(p: (Int, String)) -> String {
  let (n, s) = p
  let _ = n
  s
}
fn fo(xs: Array[String]) -> Int {
  let mut t = 0
  for i, x in xs {
    t = t + i + String::length(x)
  }
  t
}
VIBE
binder() { # binder <line> <col> <want> <label>
  local out rc=0
  out="$("$VIBE" type-at "$b" "$1" "$2" 2>/dev/null)" || rc=$?
  if [ "$out" = "$3" ] && [ "$rc" -eq 0 ]; then
    echo "ok: type-at on the $4 ($1:$2) is $3"; pass=$((pass + 1))
  else
    echo "FAIL: type-at on the $4 ($1:$2) should be '$3' (exit 0), got '$out' (exit $rc)" >&2; fail=$((fail + 1))
  fi
}
binder 7 22 String "handler arm binder msg"
binder 8 23 String "use of msg"
binder 14 10 Int "match arm binder v"
binder 14 16 Int "use of v"
binder 19 8 Int "destructuring binder n"
binder 19 11 String "destructuring binder s"
binder 25 7 Int "for index binder i"
binder 25 10 String "for value binder x"
binder 12 6 "Option[Int]" "parameter o"

# Struct / record destructuring and a guard binder.
b="$WORK/destr.vibe"
cat > "$b" <<'VIBE'
struct P { x: Int; y: String }
fn f(p: P) -> String {
  let P::{ x, y } = p
  let _ = x
  y
}
fn g() -> Int {
  let r = record { x: 10, y: 20 }
  let record { x, y } = r
  x + y
}
fn h(o: Option[Int]) -> Int {
  guard o is Some(v) else {
    return 0
  }
  v
}
VIBE
binder 3 12 Int "struct destructuring binder x"
binder 3 15 String "struct destructuring binder y"
binder 9 16 Int "record destructuring binder x"
binder 13 19 Int "guard binder v"

# A local closure whose EVERY use is a call (#3050). A callee's table row is the
# call RESULT, so there is no use to borrow a type from; the declaration and
# the callee answer with the binding's own type, which the checker records per
# local `let`. `f` in `main` shadows the top-level `f`: the callee must answer
# for the local binding, never for the module-level name of the same spelling.
b="$WORK/called_only.vibe"
cat > "$b" <<'VIBE'
fn f(s: String) -> String {
  s
}
fn main() -> Int {
  let f = (x: Int) -> x + 1
  let mut g = (a: Int, b: String) -> String::length(b) - a
  g(1, "xy") + f(1)
}
VIBE
binder 5 7 "(Int) -> Int" "declaration of a closure only ever called"
binder 7 16 "(Int) -> Int" "call of a local closure that shadows a top-level fn"
binder 6 11 "(Int, String) -> Int" "declaration of a let mut closure only ever called"
binder 7 3 "(Int, String) -> Int" "call of a let mut closure"
binder 1 4 "(String) -> String" "shadowed top-level fn"

echo "[vibe-type-at] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
