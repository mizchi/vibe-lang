#!/usr/bin/env bash
# Regression test for `vibe type-at` (LSP typed-hover MVP, docs/release-roadmap.md
# テーマ4). type_at_source locates the identifier at a 1-based (line, col) via the
# real EIdent / binding-name source offsets, typechecks the program, and prints
# the inferred type of that env-visible name. Hovering whitespace / a keyword (no
# identifier there) prints nothing.
#
# The committed seed predates this feature, so this test builds a FRESH compiler
# via install/install.sh (default, no --cli-wasm seed override) into a throwaway
# VIBE_HOME/VIBE_BIN_DIR so it never touches a real install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

# Fresh compiler (NOT the seed): the seed cannot answer type-at queries.
bash install/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

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

# Hovering a non-identifier (column 7 is the space between `export` and `let`)
# yields no type -> empty output.
ty_ws="$("$VIBE" type-at "$f" 1 7 2>/dev/null || true)"
if [ -z "$ty_ws" ]; then
  echo "ok: type-at on whitespace (1:7) is empty"; pass=$((pass + 1))
else
  echo "FAIL: type-at on whitespace (1:7) should be empty, got '$ty_ws'" >&2; fail=$((fail + 1))
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

echo "[vibe-type-at] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
