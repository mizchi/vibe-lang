#!/usr/bin/env bash
# Every builtin the checker admits enforces its argument count (#2941).
#
# `builtin_fixed_arity` is a hand chain with the central registry as its
# fallback, and the fallback returns -1 for a name with no registry row --
# "no certain arity, tolerate". Eleven names landed there, so ANY argument
# count was accepted and code generation took the call:
#
#   $ vibe check p.vibex            # clean, exit 0
#   $ vibe run p.vibex              # Path::resolve("/a", "b")
#   error: internal compiler error: `Path::resolve` (local, @call) reached code
#   generation unresolved. The type checker should have bound or rejected this
#   name, so this is a bug in the compiler and not in your program ...
#
# while `Path::resolve("/a")` -- the declared arity -- lowered fine. One
# argument too many turned into "report a compiler bug", after `vibe check`
# had said the file was clean.
#
# The eleven were found by probing every name `direct_builtin_return` admits
# with a seven-argument call: 96 of 109 answered `function arity mismatch` and
# these did not. Their arities are read from the declaration or the checker
# row -- `__set_field` from its inline three-param list, `MutList::truncate`
# from its own arm's `Array::length(args) == 2` guard -- never guessed, since
# a wrong arity here would reject correct code.
#
# Three groups, and the second is what stops the fix from being a blunt
# refusal:
#
#   1. RED      a seven-argument call to each of the eleven is refused
#   2. CONTROL  each at its DECLARED arity is still accepted, and a program
#               using them still runs
#   3. CONTROL  a name that always enforced arity still does -- a fix that
#               moved the check could lose it silently
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and says which.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 builtin-arity "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "builtin-arity: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$RUNNER" ] || { echo "builtin-arity: no runner at $RUNNER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-builtin-arity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }
check_of() { # check_of <expr> -> first diagnostic line, empty when clean
  printf 'fn main allows Console {\n  let _x = %s\n  println("ok")\n}\n' "$1" > "$WORK/p.vibex"
  VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 400 \
    bash runtime/vibe check "$WORK/p.vibex" 2>&1 | head -1
}

note "=== 1. RED: a seven-argument call is refused ==="
for n in Double::from_i64_bits_lohi Double::to_float Double::to_i64_bits_hi \
         Double::to_i64_bits_lo Float::to_double MutList::truncate \
         Path::is_absolute Path::resolve Path::to_string __len __set_field; do
  out="$(check_of "$n(0, 0, 0, 0, 0, 0, 0)")"
  case "$out" in
    *"arity mismatch"*) note "  ok   $n" ;;
    "")  note "  FAIL $n: vibe check is CLEAN -- any argument count accepted"; fail=1 ;;
    *)   note "  FAIL $n: refused, but not for arity: $(printf '%s' "$out" | cut -c1-60)"; fail=1 ;;
  esac
done

note "=== 2. CONTROL: the declared arity is still accepted ==="
# A wrong arity in the table would reject correct code, and every red row
# above would still pass. This is the half that catches that.
for e in 'Path::resolve("/a")' 'Path::is_absolute(Path::resolve("/a"))' \
         'Path::to_string(Path::resolve("/a"))' 'Double::to_i64_bits_hi(1.5)' \
         'Double::to_i64_bits_lo(1.5)' 'Double::from_i64_bits_lohi(0, 0)' \
         'Double::to_float(1.5)' '__len([1, 2])'; do
  out="$(check_of "$e")"
  if [ -z "$out" ]; then note "  ok   $e"
  else note "  FAIL $e: $(printf '%s' "$out" | sed 's/.*[0-9]: //' | cut -c1-60)"; fail=1; fi
done

note "=== 3. CONTROL: and such a program still runs ==="
cat > "$WORK/run.vibex" <<'V'
fn main allows Console {
  let hi = Double::to_i64_bits_hi(1.5)
  let lo = Double::to_i64_bits_lo(1.5)
  let back = Double::from_i64_bits_lohi(lo, hi)
  println("roundtrip=\{back} len=\{__len([1, 2, 3])}")
}
V
got="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 500 \
  bash runtime/vibe run "$WORK/run.vibex" 2>&1 | tail -1)"
want="roundtrip=1.5 len=3"
if [ "$got" = "$want" ]; then note "  ok   $got"
else note "  FAIL want '$want', got '$got'"; fail=1; fi

note "=== 4. CONTROL: a name that always enforced arity still does ==="
out="$(check_of 'Array::get([1, 2])')"
case "$out" in
  *"arity mismatch"*) note "  ok   Array::get([1, 2])" ;;
  *) note "  FAIL Array::get([1, 2]) no longer reports an arity mismatch: ${out:-<clean>}"; fail=1 ;;
esac

note
if [ "$fail" = 0 ]; then note "[builtin-arity] ok"; else note "[builtin-arity] FAIL"; fi
exit "$fail"
