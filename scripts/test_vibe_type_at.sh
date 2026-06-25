#!/usr/bin/env bash
# Regression test for `vibe type-at` (LSP typed-hover MVP, docs/release-roadmap.md
# テーマ4). type_at_source locates the identifier at a 1-based (line, col) via the
# real EIdent / binding-name source offsets, typechecks the program, and prints
# the inferred type of that env-visible name. Hovering whitespace / a keyword (no
# identifier there) prints nothing.
#
# The committed seed predates this feature, so this test builds a FRESH compiler
# via scripts/install.sh (default, no --cli-wasm seed override) into a throwaway
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
bash scripts/install.sh >/dev/null 2>&1
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

echo "[vibe-type-at] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
