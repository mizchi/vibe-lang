#!/usr/bin/env bash
# The low-level `cli_main` compile lane reports a lexer error as a DIAGNOSTIC,
# not as an uncaught throw with no sidecar (#2938).
#
# This is the lane the differential fuzzer drives
# (`--invoke cli_main <cli> <src> <out> <entry>`), and it classifies a compile
# that produced neither an artifact nor a `.diag` as COMPILE_CRASH. Measured on
# stage2 `70b1263b`, one stray backslash, 135 of 300 mutated programs were
# exactly this:
#
#   vibe: uncaught error: unexpected character: \
#   RuntimeError: unreachable
#
# with no `<out>.diag` written at all -- while a TYPE error in the same file on
# the SAME lane wrote `line 2:16-22: binding type mismatch ...` to the sidecar.
# Two kinds of rejection, one of them indistinguishable from a compiler crash.
#
# The cause is ordering, not a missing handler. The compile below IS wrapped
# (`emit_compile_diag_located`), but the ADR-0068 unstable-import gate runs
# first, and it LEXES. The FS lane's wrapper already swallows there and says
# why -- "an unreadable or uningestable entry is the compile's error to report,
# in its own words" -- and this lane called the collector directly.
#
# Four groups, and three of them are controls, because the fix is a SWALLOW and
# a swallow is exactly the shape that can quietly eat a real diagnostic:
#
#   1. RED      a lexer error writes a .diag, and does not trap
#   2. CONTROL  a TYPE error still writes its located .diag (unchanged)
#   3. CONTROL  an unstable import is STILL refused, with its own message --
#               without this, the swallow would silently undo #2277
#   4. CONTROL  a valid program still compiles to a non-empty artifact
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and SAYS which.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 single-source-lex-diag "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "single-source-lex-diag: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-ss-lex.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

# Drive the compiler exactly the way tests/fuzz/lib_oracle.sh does.
drive() { # drive <file> <entry> -> OUT, DIAG, WASM_NONEMPTY
  local f="$1" entry="$2"
  rm -f "$WORK/out.wasm" "$WORK/out.wasm.diag"
  OUT="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw timeout 120 \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI" \
    "$WORK/$f" "$WORK/out.wasm" "$entry" 2>&1)"
  DIAG=""
  [ -s "$WORK/out.wasm.diag" ] && DIAG="$(cat "$WORK/out.wasm.diag")"
  if [ -s "$WORK/out.wasm" ]; then WASM_NONEMPTY=1; else WASM_NONEMPTY=0; fi
}

printf 'fn main allows Console {\n  let x = 1 \\ 2\n  println("hi")\n}\n'      > "$WORK/lex.vibex"
printf 'fn main allows Console {\n  let x: Int = "nope"\n  println("hi")\n}\n' > "$WORK/type.vibex"
printf 'import @vibe/concurrent {\n  TaskGroup\n}\n\nfn main allows Console {\n  println("hi")\n}\n' > "$WORK/unstable.vibex"
printf 'fn main allows Console {\n  println("good")\n}\n'                      > "$WORK/good.vibex"

note "=== 1. RED: a lexer error is a diagnostic, not an uncaught throw ==="
drive lex.vibex main
if printf '%s' "$OUT" | grep -qF "uncaught error"; then
  note "  FAIL the throw is still uncaught -- the host printed it and trapped"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
elif [ -z "$DIAG" ]; then
  note "  FAIL no .diag was written -- the fuzzer cannot tell this from a compiler crash"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
elif ! printf '%s' "$DIAG" | grep -qF "unexpected character"; then
  note "  FAIL a .diag was written but not about the lexer error: $DIAG"; fail=1
else
  note "  ok   diag: $(printf '%s' "$DIAG" | head -1 | cut -c1-70)"
fi

note "=== 2. CONTROL: a type error still writes its located diagnostic ==="
drive type.vibex main
if printf '%s' "$DIAG" | grep -qE 'line [0-9]+:[0-9]+' && printf '%s' "$DIAG" | grep -qF "type mismatch"; then
  note "  ok   diag: $(printf '%s' "$DIAG" | head -1 | cut -c1-70)"
else
  note "  FAIL the type-error diagnostic changed: ${DIAG:-<none>}"; fail=1
fi

note "=== 3. CONTROL: an unstable import is still refused (#2277) ==="
# The fix is a SWALLOW around the gate that produces this message. If the
# swallow is too wide, this row goes quiet and an unstable import builds.
drive unstable.vibex main
if [ "$WASM_NONEMPTY" = 1 ]; then
  note "  FAIL an unstable import BUILT -- the swallow ate the ADR-0068 gate"; fail=1
elif ! printf '%s' "$DIAG" | grep -qF "VIBE_UNSTABLE=1"; then
  note "  FAIL the unstable refusal is gone: ${DIAG:-<none>}"; fail=1
else
  note "  ok   still refused, and still says how to opt in"
fi

note "=== 4. CONTROL: a valid program still compiles ==="
drive good.vibex main
if [ "$WASM_NONEMPTY" = 1 ] && [ -z "$DIAG" ]; then
  note "  ok   artifact written, no diagnostic"
else
  note "  FAIL valid program did not compile: diag=${DIAG:-<none>} wasm_nonempty=$WASM_NONEMPTY"
  printf '%s\n' "$OUT" | head -2 | sed 's/^/        /'; fail=1
fi

note
if [ "$fail" = 0 ]; then note "[single-source-lex-diag] ok"; else note "[single-source-lex-diag] FAIL"; fi
exit "$fail"
