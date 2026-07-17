#!/usr/bin/env bash
# Regression test for `vibe diagnostics` (LSP multi-diagnostic MVP, テーマ4 土台A).
# The recovering parser (parse_program_recovering) NEVER rethrows on the first
# syntax error: it records the located (`line:col`) message, resynchronizes at
# the next top-level statement boundary, and keeps parsing. So a file with two
# INDEPENDENT top-level syntax errors yields TWO located diagnostics referencing
# DIFFERENT lines — proving recovery collected past the first error. A clean
# file yields empty output.
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

# Fresh compiler (NOT the seed): the seed predates `vibe diagnostics`.
bash scripts/install.sh >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

pass=0; fail=0

# Two INDEPENDENT top-level syntax errors with a valid statement between them.
# `export let a = = 1` (line 1) and `export let b = = 2` (line 3) are both bad
# (double `=`); `export let ok = 1` (line 2) parses fine. Recovery must surface
# BOTH errors, located on DIFFERENT lines (line 1 and line 3).
# #946: EXACTLY 2 — the anchor-based resync + (pos, message) dedupe must not
# re-report the same broken statement 4-5x from intermediate restart points.
multi="$WORK/multi.vibe"
printf 'export let a = = 1\nexport let ok = 1\nexport let b = = 2\n' > "$multi"

out="$("$VIBE" diagnostics "$multi" 2>/dev/null || true)"
nlines="$(printf '%s\n' "$out" | grep -c 'line ' || true)"
if [ "$nlines" -eq 2 ]; then
  echo "ok: two independent syntax errors -> exactly $nlines located diagnostics"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 2 located diagnostics (dedup, #946), got $nlines:" >&2
  printf '%s\n' "$out" >&2
  fail=$((fail + 1))
fi

if printf '%s\n' "$out" | grep -q 'line 1:' && printf '%s\n' "$out" | grep -q 'line 3:'; then
  echo "ok: diagnostics reference DIFFERENT lines (line 1 and line 3)"; pass=$((pass + 1))
else
  echo "FAIL: expected diagnostics on line 1 AND line 3 (recovery past first error):" >&2
  printf '%s\n' "$out" >&2
  fail=$((fail + 1))
fi

# #946: a LEXER error must surface as exactly one located diagnostic, not an
# empty ("clean") report. `$` is not a lexable character; the recovering lexer
# records it at line 1 col 18 and diagnostics reports it located.
lexerr="$WORK/lexerr.vibe"
printf 'export let a = 1 $\n' > "$lexerr"
out_lex="$("$VIBE" diagnostics "$lexerr" 2>/dev/null || true)"
nlex="$(printf '%s\n' "$out_lex" | grep -c 'line ' || true)"
if [ "$nlex" -eq 1 ] && printf '%s\n' "$out_lex" | grep -q 'line 1:18: unexpected character'; then
  echo "ok: lexer error -> 1 located diagnostic"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 1 located lexer diagnostic (line 1:18: unexpected character...), got:" >&2
  printf '%s\n' "$out_lex" >&2
  fail=$((fail + 1))
fi

# #963 (Codex P2 on #946): a bad escape INSIDE a string must yield exactly ONE
# diagnostic. The recovering lexer resumes past the whole quoted construct;
# resuming inside it re-lexed the interior and invented follow-on noise (the
# backslash as an unexpected char, the closing quote as a new unterminated
# string).
badesc="$WORK/badesc.vibe"
printf 'let s = "\\q"\n' > "$badesc"
out_esc="$("$VIBE" diagnostics "$badesc" 2>/dev/null || true)"
nesc="$(printf '%s\n' "$out_esc" | grep -c 'line ' || true)"
if [ "$nesc" -eq 1 ] && printf '%s\n' "$out_esc" | grep -q 'line 1:9: invalid escape'; then
  echo "ok: bad string escape -> exactly 1 located diagnostic"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 1 located diagnostic (line 1:9: invalid escape...), got:" >&2
  printf '%s\n' "$out_esc" >&2
  fail=$((fail + 1))
fi

# #963 (Codex P2 on #946): when a failed statement's error anchor IS the first
# token of the NEXT top-level statement (`export let a =` runs into `test`),
# recovery must resume AT that anchor so the second statement's own independent
# error is still reported: exactly 2 diagnostics (line 2:1 + line 2:16).
anchor2="$WORK/anchor2.vibe"
printf 'export let a =\ntest "x" { 1 + }\n' > "$anchor2"
out_a2="$("$VIBE" diagnostics "$anchor2" 2>/dev/null || true)"
na2="$(printf '%s\n' "$out_a2" | grep -c 'line ' || true)"
if [ "$na2" -eq 2 ] && printf '%s\n' "$out_a2" | grep -q 'line 2:1: ' && printf '%s\n' "$out_a2" | grep -q 'line 2:16: '; then
  echo "ok: anchor-on-next-statement -> both independent errors reported"; pass=$((pass + 1))
else
  echo "FAIL: expected exactly 2 diagnostics (line 2:1 and line 2:16), got:" >&2
  printf '%s\n' "$out_a2" >&2
  fail=$((fail + 1))
fi

# A clean file -> empty output.
clean="$WORK/clean.vibe"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$clean"
out_clean="$("$VIBE" diagnostics "$clean" 2>/dev/null || true)"
if [ -z "$out_clean" ]; then
  echo "ok: clean file -> empty diagnostics"; pass=$((pass + 1))
else
  echo "FAIL: clean file should have no diagnostics, got '$out_clean'" >&2; fail=$((fail + 1))
fi

echo "[vibe-diagnostics] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
