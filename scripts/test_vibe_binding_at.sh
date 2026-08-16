#!/usr/bin/env bash
# Regression test for `vibe binding-at` (AST-accurate binding occurrences, the
# scope-precision rename / references groundwork, docs/release-roadmap.md テーマ4).
# binding_occurrences locates the identifier at a 1-based (line, col) via the real
# EIdent / binding-name source offsets and prints, one `START END` per line, the
# source span of EVERY occurrence of that name across the AST. AST-accurate: no
# false matches inside strings/comments/partial words. Hovering whitespace (no
# identifier) prints nothing.
#
# Scope-aware (テーマ4): the cursor identifier is resolved to its nearest
# enclosing binding (let / param / for / match binder) via a scope-stack walk, so
# distinct same-named locals in different scopes are NOT conflated. Top-level /
# module bindings still group file-wide by name.
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

# Fresh compiler (NOT the seed): the seed cannot answer binding-at queries.
bash install/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0

# Source: `helper` is DEFINED on line 1 and USED twice on line 2.
#   line 1: export let helper = (x: Int) -> Int { x * 2 }
#   line 2: export let main = () -> Int { helper(21) + helper(1) }
# `export let ` is 11 chars, so the binding name `helper` starts at offset 11 =
# 1-based column 12. `binding-at f 1 12` lands on the definition name and must
# return >=3 spans (the definition + both uses).
f="$WORK/helper.vibe"
printf 'export let helper = (x: Int) -> Int { x * 2 }\nexport let main = () -> Int { helper(21) + helper(1) }\n' > "$f"

src="$(cat "$f")"

occ="$("$VIBE" binding-at "$f" 1 12 2>/dev/null || true)"
count="$(printf '%s' "$occ" | grep -c '[0-9]' || true)"
if [ "${count:-0}" -ge 3 ]; then
  echo "ok: binding-at on 'helper' def (1:12) returned $count occurrences"; pass=$((pass + 1))
else
  echo "FAIL: binding-at on 'helper' def (1:12) should return >=3 occurrences, got $count:" >&2
  printf '%s\n' "$occ" >&2; fail=$((fail + 1))
fi

# Each emitted span must correspond to `helper` (length 6): a [START END) slice of
# the source of length 6 == END - START. (We don't assume the source substring
# equals "helper" textually here since awk slicing of multibyte/offset math is
# brittle in shell; the fixed length 6 is the AST-accurate invariant for this
# single-name file.)
len_ok=1
while IFS=' ' read -r s e; do
  [ -n "$s" ] || continue
  span=$((e - s))
  if [ "$span" -ne 6 ]; then
    echo "FAIL: span ($s,$e) has length $span, expected 6 (len of 'helper')" >&2
    len_ok=0
  fi
done <<EOF
$occ
EOF
if [ "$len_ok" -eq 1 ]; then
  echo "ok: every binding-at span has length 6 (== len 'helper')"; pass=$((pass + 1))
else
  fail=$((fail + 1))
fi

# Cross-check: the FIRST span start must be offset 11 (the definition name), the
# AST-accurate position of the binding under the cursor.
first_start="$(printf '%s' "$occ" | head -n1 | awk '{print $1}')"
if [ "${first_start:-x}" = "11" ]; then
  echo "ok: first occurrence starts at offset 11 (the 'helper' definition name)"; pass=$((pass + 1))
else
  echo "FAIL: first occurrence should start at offset 11, got '${first_start:-}'" >&2; fail=$((fail + 1))
fi

# Hovering whitespace (column 7 is the space between `export` and `let` on line 1)
# yields no identifier -> empty output.
occ_ws="$("$VIBE" binding-at "$f" 1 7 2>/dev/null || true)"
if [ -z "$occ_ws" ]; then
  echo "ok: binding-at on whitespace (1:7) is empty"; pass=$((pass + 1))
else
  echo "FAIL: binding-at on whitespace (1:7) should be empty, got '$occ_ws'" >&2; fail=$((fail + 1))
fi

# --- Scope precision (テーマ4): distinct same-named locals must NOT be conflated.
#   line 1: export let f = (x: Int) -> Int { x + 1 }
#   line 2: export let g = (x: Int) -> Int { x * 2 }
# Line 1 is exactly 40 chars + newline, so line 1 spans char offsets [0, 40] and
# line 2 starts at offset 41. The `x` parameter in `f` is at offset 16 (1-based
# column 17); its use is at offset 33. `binding-at <file> 1 17` must return ONLY
# those two line-1 `x` spans (the param + its single use in f), and NOT the two
# `x` spans in g on line 2 (offsets 57, 74). A pre-scope (name-wide) result would
# return all FOUR `x` spans.
fg="$WORK/fg.vibe"
printf 'export let f = (x: Int) -> Int { x + 1 }\nexport let g = (x: Int) -> Int { x * 2 }\n' > "$fg"

occ_fg="$("$VIBE" binding-at "$fg" 1 17 2>/dev/null || true)"
fg_count="$(printf '%s\n' "$occ_fg" | grep -c '[0-9]' || true)"
if [ "${fg_count:-0}" -eq 2 ]; then
  echo "ok: scope-precise binding-at on 'x' in f (1:17) returned exactly 2 occurrences (param + use in f)"; pass=$((pass + 1))
else
  echo "FAIL: scope-precise binding-at on 'x' in f (1:17) should return exactly 2 occurrences (not g's x), got $fg_count:" >&2
  printf '%s\n' "$occ_fg" >&2; fail=$((fail + 1))
fi

# Every returned span must fall on LINE 1 (offset < 41) — proving g's line-2 `x`
# (offsets 57/74) was excluded by the scope analysis.
fg_lines_ok=1
fg_seen=0
while IFS=' ' read -r s e; do
  [ -n "$s" ] || continue
  fg_seen=$((fg_seen + 1))
  if [ "$s" -ge 41 ] || [ "$e" -gt 41 ]; then
    echo "FAIL: span ($s,$e) is on line 2 (offset >= 41) — g's x leaked into f's binding" >&2
    fg_lines_ok=0
  fi
done <<EOF
$occ_fg
EOF
if [ "$fg_lines_ok" -eq 1 ] && [ "$fg_seen" -eq 2 ]; then
  echo "ok: both f-scope 'x' spans fall within line 1 (g's line-2 'x' excluded)"; pass=$((pass + 1))
else
  echo "FAIL: f-scope 'x' spans must all be on line 1 and number 2 (seen $fg_seen)" >&2; fail=$((fail + 1))
fi

# Symmetry: `x` in g (line 2, column 17 -> offset 57) must return ONLY g's two
# line-2 spans, never touching f's line-1 `x`.
occ_g="$("$VIBE" binding-at "$fg" 2 17 2>/dev/null || true)"
g_count="$(printf '%s\n' "$occ_g" | grep -c '[0-9]' || true)"
g_lines_ok=1
while IFS=' ' read -r s e; do
  [ -n "$s" ] || continue
  if [ "$s" -lt 41 ]; then
    echo "FAIL: g's binding span ($s,$e) leaked onto line 1 (f's x)" >&2
    g_lines_ok=0
  fi
done <<EOF
$occ_g
EOF
if [ "${g_count:-0}" -eq 2 ] && [ "$g_lines_ok" -eq 1 ]; then
  echo "ok: scope-precise binding-at on 'x' in g (2:17) returned exactly its own 2 line-2 spans"; pass=$((pass + 1))
else
  echo "FAIL: scope-precise binding-at on 'x' in g (2:17) should return exactly 2 line-2 spans, got $g_count:" >&2
  printf '%s\n' "$occ_g" >&2; fail=$((fail + 1))
fi

echo "[vibe-binding-at] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
