#!/usr/bin/env bash
# #2137 / #1511: which callee shapes a `handle` body may contain, and what the
# diagnostic says when one is rejected.
#
# This exists as its own gate because `fixtures/typecheck/expected.tsv` CANNOT
# answer the question. That lane compiles every fixture with `__no_entry__`,
# which skips the entry-boundary lowering where this check runs -- so it records
# `ok` for a program `vibe check` rejects. Measured: the
# handle_callee_local_closure_arg fixture is `ok` in that lane and
# `error: handle of effect 'Ask' cannot be compiled here` from the CLI. Every
# case below is therefore compiled with a REAL entry name.
#
# The message matters as much as the verdict. It used to blame "a local binding
# or a closure parameter", and both of those compile; the shapes it actually
# rejects were not mentioned. A reader following it went looking for a
# diagnostic they would never see.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${HANDLE_GATE_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  [ -f "$STAGE2" ] || { echo "handle-eligibility: HANDLE_GATE_STAGE2=$STAGE2 does not exist" >&2; exit 1; }
else
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] && { STAGE2="${gen}stage2.wasm"; break; }
  done
  [ -n "${STAGE2:-}" ] || STAGE2="bootstrap/seed/compiler.wasm"
  [ -s "$STAGE2" ] || { echo "handle-eligibility: no compiler available" >&2; exit 1; }
fi

WORK="$ROOT_DIR/_build/_handle_eligibility"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fails=0
note() { printf 'handle-eligibility: ok: %s\n' "$1"; }
bad() { printf 'handle-eligibility: FAIL: %s\n' "$1" >&2; fails=1; }

PRELUDE='effect Ask { Get() -> Int }
fn ask_once() -> Int with Ask { perform Ask::Get() }'

judge() { # judge <name> <body>
  local name="$1" body="$2"
  printf '%s\n%s\n' "$PRELUDE" "$body" > "$WORK/$name.vibe"
  rm -f "$WORK/$name.wasm" "$WORK/$name.wasm.diag"
  # A REAL entry name, not __no_entry__ -- that is the whole point of this gate.
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$WORK/$name.vibe" "$WORK/$name.wasm" main >/dev/null 2>&1 || true
  if [ -s "$WORK/$name.wasm" ]; then echo "OK"; else
    head -c 600 "$WORK/$name.wasm.diag" 2>/dev/null | tr -d '\n'
  fi
}

expect_ok() { # expect_ok <name> <body>
  local got; got="$(judge "$1" "$2")"
  [ "$got" = "OK" ] && note "$1 compiles" || bad "$1 should compile; got: $(echo "$got" | head -c 140)"
}
expect_rejected_by_eligibility() { # <name> <body>
  local got; got="$(judge "$1" "$2")"
  case "$got" in
    OK) bad "$1 should be REJECTED by handle eligibility, but it compiled" ;;
    *"carries no effect row"*) note "$1 rejected, and the message names the effect row" ;;
    *"cannot be compiled here"*) bad "$1 is rejected here, but the message does not name the missing effect row -- it must say what to edit (#2137): $(echo "$got" | head -c 160)" ;;
    *) bad "$1 rejected by something else: $(echo "$got" | head -c 160)" ;;
  esac
}

# --- Accepted. Each of these was named as rejected by the old message, or by
# --- the cheatsheet prose, and each compiles.
expect_ok direct_perform '
fn main() -> Int { handle { ask_once() } with Ask { Get() => resume(10) } }'

expect_ok toplevel_fn_callee '
fn bump2(x: Int) -> Int { x + 1 }
fn main() -> Int { handle { bump2(ask_once()) } with Ask { Get() => resume(10) } }'

expect_ok closure_parameter_with_row '
fn apply(f: () -> Int with Ask) -> Int with Ask { f() }
fn main() -> Int { handle { apply(ask_once) } with Ask { Get() => resume(1) } }'

expect_ok local_binding_with_row '
fn main() -> Int {
  let f: () -> Int with Ask = () -> { ask_once() }
  handle { f() } with Ask { Get() => resume(1) }
}'

expect_ok local_closure_annotated_with_row '
fn main() -> Int {
  let bump: (Int) -> Int with Ask = (x: Int) -> Int { x + 1 }
  handle { bump(ask_once()) } with Ask { Get() => resume(10) }
}'

# --- Rejected: a local call target whose type carries no effect row. The three
# --- cases differ only in where the perform is, which does NOT matter -- that
# --- independence is the part the old message got wrong.
expect_rejected_by_eligibility perform_in_the_argument '
fn main() -> Int {
  let bump = (x: Int) -> Int { x + 1 }
  handle { bump(ask_once()) } with Ask { Get() => resume(10) }
}'

expect_rejected_by_eligibility perform_hoisted_out_of_the_call '
fn main() -> Int {
  let bump = (x: Int) -> Int { x + 1 }
  handle { let y = ask_once(); bump(y) } with Ask { Get() => resume(10) }
}'

expect_rejected_by_eligibility perform_beside_the_call '
fn main() -> Int {
  let bump = (x: Int) -> Int { x + 1 }
  handle { bump(1) + ask_once() } with Ask { Get() => resume(10) }
}'

# An annotation is not enough; it has to carry the ROW.
expect_rejected_by_eligibility annotated_type_without_a_row '
fn main() -> Int {
  let bump: (Int) -> Int = (x: Int) -> Int { x + 1 }
  handle { bump(1) + ask_once() } with Ask { Get() => resume(10) }
}'

[ "$fails" -eq 0 ] || exit 1
echo "handle-eligibility: ok (5 accepted shapes, 4 rejected with an actionable message)"
