#!/usr/bin/env bash
# Regression test for `vibe binding-at` (AST-accurate binding occurrences, the
# scope-precision rename / references groundwork, docs/release-roadmap.md テーマ4).
# binding_occurrences locates the identifier at a 1-based (line, col) via the real
# EIdent / binding-name source offsets and prints, one `START END` per line, the
# source span of EVERY occurrence of that name across the AST. AST-accurate: no
# false matches inside strings/comments/partial words. Hovering whitespace (no
# identifier) prints nothing.
#
# MVP LIMITATION (honest): matching is name-based across the whole file, with NO
# shadowing analysis yet — distinct same-named locals are grouped as one. Still
# strictly more accurate than a whole-file text scan.
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

# Fresh compiler (NOT the seed): the seed cannot answer binding-at queries.
bash scripts/install.sh >/dev/null 2>&1
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

echo "[vibe-binding-at] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
