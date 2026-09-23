#!/usr/bin/env bash
# A `.vibex` entry's LEXER error names its file and its position (#2938), and
# so does its PARSE error (#2948).
#
# The same lexer error reached the reader three different ways depending on how
# it was asked -- measured on stage2 `25a3b9f96`:
#
#   vibe check e.vibex    error: line 2:13: unexpected character: \
#   vibe build e.vibex    error: unexpected character: \
#   vibe build e2.vibe    error: <path>: unexpected character: \
#
# `validate_vibex_entry_source` is the only parse a `.vibex` entry reaches
# before the module walk, and it ran `parse_program_preserving(lex(source))`
# with no handler -- so a `.vibex` entry never reached `located_parse_uncached`,
# which is where a `.vibe` entry picks up its path.
#
# Six groups. Only the first is the fix; the rest are what keep it from being
# "prefix everything":
#
#   1. RED      a .vibex entry's lexer error names the file AND the position
#   2. CONTROL  vibe check on the same file is unchanged
#   3. CONTROL  a .vibe entry still gets path + position (the #2946 lane)
#   4. CONTROL  the .vibex SHAPE diagnostics are untouched -- they throw from
#               the same function, outside the parse, and already named the
#               file, so a careless handler would double-prefix them
#   5. CONTROL  a valid .vibex still builds and RUNS
#   6. RED      a .vibex PARSE error names the file and the SAME position
#               the .vibe lane reports for identical bytes (#2948). The
#               validation parse used to be the tokens-only
#               `parse_program_preserving`, which has no starts table and so
#               (rightly) declined to locate. It is now the located preserving
#               parse. The row compares against the .vibe answer instead of a
#               hard-coded position, so it cannot pass by inventing one. It
#               also holds for `run` (the preflight parse) and `serve`, and a
#               message built with an internal token index (`at #N`) must not
#               reach the reader on either lane.
#   7. RED      the other two verbs that read a user-named entry and lex it --
#               `serve` and `build --wit` -- answer the same way. `run` does
#               not reach `validate_vibex_entry_source` at all: it lexes the
#               entry itself in `preflight_entry_authority`, which is why the
#               first version of this fix left `vibe run` bare and group 1
#               caught it.
#   8. CONTROL  both of those verbs still do their job on a good file, and a
#               parseable file that serve REJECTS for its own reason still
#               gets serve's own diagnostic -- the parse must not swallow the
#               check that follows it.
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and SAYS which.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 vibex-entry-lex "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "vibex-entry-lex: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$RUNNER" ] || { echo "vibex-entry-lex: no runner at $RUNNER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-vibex-lex.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

# A stray backslash on line 2, column 13: the cheapest thing that cannot be
# scanned, and the position `vibe check` already reported for it.
printf 'fn main allows Console {\n  let x = 1 \\ 2\n  println("hi")\n}\n' > "$WORK/lex.vibex"
printf 'fn main allows Console {\n  let x = 1 \\ 2\n  println("hi")\n}\n' > "$WORK/lex.vibe"
printf 'fn main allows Console {\n  let y = (\n  println("hi")\n}\n'       > "$WORK/parse.vibex"
cp "$WORK/parse.vibex" "$WORK/parse.vibe"
printf 'fn quiet() -> Int allows Console {\n  42\n}\n\nfn main allows Console {\n  println("\\{quiet()}")\n}\n' > "$WORK/allows.vibex"
cp "$WORK/allows.vibex" "$WORK/allows.vibe"
printf 'export fn helper() -> Int {\n  1\n}\n\nfn main allows Console {\n  println("hi")\n}\n' > "$WORK/shape.vibex"
printf 'fn main allows Console {\n  println("ok-42")\n}\n'                 > "$WORK/good.vibex"
printf 'export fn helper() -> Int {\n  let x = 1 \\ 2\n  x\n}\n'             > "$WORK/lexlib.vibe"
printf 'export fn helper(x: Int) -> Int {\n  x + 1\n}\n'                   > "$WORK/goodlib.vibe"

ask() { # ask <verb> <file> [extra args] -> OUT
  local verb="$1" f="$2"; shift 2
  OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" VIBE_BUILD_CACHE_DIR="$WORK/cache" \
    timeout 600 bash runtime/vibe "$verb" "$WORK/$f" "$@" 2>&1)"
}
positions() { printf '%s' "$1" | grep -o 'line [0-9][0-9]*:[0-9][0-9]*:' | wc -l | tr -d ' '; }

note "=== 1. RED: a .vibex entry's lexer error names the file and the position ==="
for verb in build run; do
  if [ "$verb" = build ]; then ask build lex.vibex -o "$WORK/lex.wasm"; else ask run lex.vibex; fi
  if ! printf '%s' "$OUT" | grep -qF "lex.vibex"; then
    note "  FAIL $verb: the message does not name the entry file"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  if ! printf '%s' "$OUT" | grep -qF "line 2:13:"; then
    note "  FAIL $verb: no position -- vibe check answers line 2:13 for this file"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  if ! printf '%s' "$OUT" | grep -qF "unexpected character"; then
    note "  FAIL $verb: the message no longer says what is wrong"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  note "  ok   vibe $verb reports lex.vibex at line 2:13"
done

note "=== 2. CONTROL: vibe check on the same .vibex is unchanged ==="
ask check lex.vibex
if printf '%s' "$OUT" | grep -qF "line 2:13: unexpected character"; then
  note "  ok   vibe check still answers line 2:13"
else
  note "  FAIL the check lane regressed:"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi

note "=== 3. CONTROL: a .vibe entry still gets path and position (#2946) ==="
ask build lex.vibe -o "$WORK/lexvibe.wasm"
if printf '%s' "$OUT" | grep -qF "lex.vibe:" && printf '%s' "$OUT" | grep -qF "line 2:13:"; then
  note "  ok   the .vibe lane still reports path + line 2:13"
else
  note "  FAIL the .vibe lane regressed:"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi

note "=== 4. CONTROL: the .vibex shape diagnostics are untouched ==="
# These throw from the same function, OUTSIDE the parse, and already named the
# file. A handler wrapped one statement too wide would prefix them again.
ask build shape.vibex -o "$WORK/shape.wasm"
if ! printf '%s' "$OUT" | grep -qF "executable root and has no export surface"; then
  note "  FAIL the export-surface diagnostic was lost:"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
elif [ "$(printf '%s' "$OUT" | grep -o 'shape.vibex:' | wc -l | tr -d ' ')" != 1 ]; then
  note "  FAIL the file name appears more than once -- double-prefixed:"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
else
  note "  ok   named once, and still says what to move where"
fi

note "=== 5. CONTROL: a valid .vibex still builds and runs ==="
ask check good.vibex
if [ -n "$OUT" ]; then
  note "  FAIL a valid .vibex no longer checks:"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
else note "  ok   vibe check is clean"; fi
ask run good.vibex
got="$(printf '%s' "$OUT" | tail -1)"
if [ "$got" = "ok-42" ]; then note "  ok   and answers: ok-42"
else note "  FAIL want 'ok-42', got '$got'"; fail=1; fi

note "=== 6. RED: a .vibex PARSE error carries the position the .vibe lane reports (#2948) ==="
# locpart <out> -> the first `line L:C: message` of a diagnostic, path stripped
locpart() { printf '%s' "$1" | grep -o 'line [0-9][0-9]*:[0-9][0-9]*: .*' | head -1; }
for pair in "parse:expected ')' or ','" "allows:grants authority"; do
  stem="${pair%%:*}"; what="${pair#*:}"
  ask build "$stem.vibe" -o "$WORK/$stem.vibe.wasm"; want="$(locpart "$OUT")"
  if [ -z "$want" ] || ! printf '%s' "$want" | grep -qF "$what"; then
    note "  FAIL control: the .vibe lane gives no located '$what' for $stem"
    printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1; continue
  fi
  for verb in build run serve; do
    case "$verb" in
      build) ask build "$stem.vibex" -o "$WORK/$stem.wasm" ;;
      run)   ask run "$stem.vibex" ;;
      serve) ask serve "$stem.vibex" -o "$WORK/$stem.component.wasm" ;;
    esac
    if ! printf '%s' "$OUT" | grep -qF "$stem.vibex"; then
      note "  FAIL $verb $stem.vibex: the message does not name the file"
      printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
    elif printf '%s' "$OUT" | grep -q ' at #[0-9]'; then
      note "  FAIL $verb $stem.vibex: a parser token index reached the reader"
      printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
    elif [ "$(locpart "$OUT")" != "$want" ]; then
      note "  FAIL $verb $stem.vibex: want '$want' (the .vibe answer)"
      printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
    elif [ "$(positions "$OUT")" != 1 ]; then
      note "  FAIL $verb $stem.vibex: the position is doubled"
      printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
    else
      note "  ok   vibe $verb $stem.vibex: ${want%%: *}"
    fi
  done
done

note "=== 7. RED: serve and build --wit read an entry the same way ==="
# `serve` lexes the entry in its own handler validation; `build --wit` lexes it
# to read the export surface. Both held the path and threw the lexer's bare
# text. `--wit` refuses a .vibex for an unrelated reason, so its row uses a
# library file.
ask serve lex.vibex -o "$WORK/lex.component.wasm"
if printf '%s' "$OUT" | grep -qF "lex.vibex" && printf '%s' "$OUT" | grep -qF "line 2:13:"; then
  note "  ok   vibe serve reports lex.vibex at line 2:13"
else
  note "  FAIL serve: want the file and line 2:13"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi
ask build lexlib.vibe --wit -o "$WORK/lexlib.wit"
if printf '%s' "$OUT" | grep -qF "lexlib.vibe" && printf '%s' "$OUT" | grep -qF "line 2:13:"; then
  note "  ok   vibe build --wit reports lexlib.vibe at line 2:13"
else
  note "  FAIL build --wit: want the file and line 2:13"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi

note "=== 8. CONTROL: those verbs still work, and serve still runs its own check ==="
ask build goodlib.vibe --wit -o "$WORK/goodlib.wit"
if [ -s "$WORK/goodlib.wit" ] && grep -q "world goodlib" "$WORK/goodlib.wit"; then
  note "  ok   build --wit still writes a world for a good file"
else
  note "  FAIL build --wit produced no usable world"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi
# Parseable, but not a serve handler. The parse must hand the statements on,
# not swallow them -- otherwise the rows above would pass with serve broken.
ask serve goodlib.vibe -o "$WORK/goodlib.component.wasm"
if printf '%s' "$OUT" | grep -qF "no exported \`handler\`"; then
  note "  ok   serve still reaches its own handler diagnostic"
else
  note "  FAIL serve's own check no longer runs"; printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi

note
if [ "$fail" = 0 ]; then note "[vibex-entry-lex] ok"; else note "[vibex-entry-lex] FAIL"; fi
exit "$fail"
