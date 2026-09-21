#!/usr/bin/env bash
# An imported file's LEXER error carries a line:col, the way the same file
# checked directly already did (#2946).
#
# Before this, one file got two different answers depending on which file the
# compiler was asked about -- measured identically on three independent stage2
# artifacts (`9b182ab0f`, `25a3b9f96`, `c4d075f9c`):
#
#   $ vibe check dep.vibe        -> error: line 2:13: unexpected character: \
#   $ vibe check main.vibex      -> error: /abs/dep.vibe: unexpected character: \
#
# `located_parse_uncached` wraps the lex and the parse in ONE handler and
# prefixes the path. A parse error leaves `parse_program_located` already
# carrying `line L:C:`, so the prefix completes it; a lexer error is thrown
# from inside the scan and is bare text, so the prefix is all it ever gets.
#
# Four groups, and the last three are what stop the fix from being "prefix
# everything with a position":
#
#   1. RED      an imported file's lexer error names the file AND the position
#   2. CONTROL  the same file checked DIRECTLY still answers as it always did
#   3. CONTROL  an imported PARSE error is not double-located -- it already had
#               a position, so exactly one `line ` prefix may appear
#   4. CONTROL  a clean import still checks, compiles and RUNS with the right
#               answer, so "refuse every import" cannot pass groups 1-3
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and SAYS which -- never silently, since
#                  the committed seed is a different compiler.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 imported-lex-located "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "imported-lex-located: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$RUNNER" ] || { echo "imported-lex-located: no runner at $RUNNER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-imported-lex.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

# A lexer error: a stray backslash, the cheapest thing that cannot be scanned.
# Column 13 is the backslash on line 2, which is what the direct check reports.
printf 'export fn helper() -> Int {\n  let x = 1 \\ 2\n  x\n}\n' > "$WORK/dep.vibe"
# A PARSE error: scans fine, does not parse. Used by group 3.
printf 'export fn helper2() -> Int {\n  let y = (\n  y\n}\n' > "$WORK/pdep.vibe"
printf 'export fn helper3() -> Int {\n  41\n}\n' > "$WORK/okdep.vibe"

mk_main() { # mk_main <dep basename> <fn name> -> writes $WORK/$3.vibex
  printf 'import ./%s { %s }\n\nfn main allows Console {\n  println("\\{%s()}")\n}\n' \
    "$1" "$2" "$2" > "$WORK/$3.vibex"
}
mk_main dep.vibe helper lexmain
mk_main pdep.vibe helper2 parsemain
mk_main okdep.vibe helper3 okmain

ask() { # ask <verb> <file> -> OUT
  OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" timeout 600 \
    bash runtime/vibe "$1" "$WORK/$2" 2>&1)"
}

note "=== 1. RED: an imported lexer error names the file AND the position ==="
for verb in check build run; do
  ask "$verb" lexmain.vibex
  if ! printf '%s' "$OUT" | grep -qF "dep.vibe"; then
    note "  FAIL $verb: the message does not name the imported file"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  if ! printf '%s' "$OUT" | grep -qF "unexpected character"; then
    note "  FAIL $verb: the message does not say what is wrong"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  if ! printf '%s' "$OUT" | grep -qF "line 2:13:"; then
    note "  FAIL $verb: no position -- the reader must scan the file to find it"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  note "  ok   vibe $verb reports dep.vibe at line 2:13"
done

note "=== 2. CONTROL: the same file checked directly is unchanged ==="
ask check dep.vibe
if printf '%s' "$OUT" | grep -qF "line 2:13: unexpected character"; then
  note "  ok   vibe check dep.vibe still answers line 2:13"
else
  note "  FAIL the direct answer regressed:"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi

note "=== 3. CONTROL: an imported PARSE error is not double-located ==="
# It already carried `line L:C:` from parse_program_located. A fix that
# prefixed unconditionally would produce `line 3:3: line 3:3: ...` here and
# still pass group 1.
ask check parsemain.vibex
n="$(printf '%s' "$OUT" | grep -o 'line [0-9][0-9]*:[0-9][0-9]*:' | wc -l | tr -d ' ')"
if [ "$n" = 1 ]; then
  note "  ok   exactly one position: $(printf '%s' "$OUT" | head -1 | cut -c1-72)"
else
  note "  FAIL expected exactly 1 'line L:C:' in the message, got $n"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi
if printf '%s' "$OUT" | grep -qF "pdep.vibe"; then note "  ok   and still names the file"
else note "  FAIL the parse diagnostic lost the file name"; fail=1; fi

note "=== 4. CONTROL: a clean import still checks, compiles and runs ==="
ask check okmain.vibex
if [ -z "$OUT" ]; then note "  ok   vibe check is clean"
else note "  FAIL a clean import no longer checks:"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; fi
ask run okmain.vibex
got="$(printf '%s' "$OUT" | tail -1)"
if [ "$got" = "41" ]; then note "  ok   and answers: 41"
else note "  FAIL want '41', got '$got'"; fail=1; fi

note
if [ "$fail" = 0 ]; then note "[imported-lex-located] ok"; else note "[imported-lex-located] FAIL"; fi
exit "$fail"
