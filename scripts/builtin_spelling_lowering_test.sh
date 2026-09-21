#!/usr/bin/env bash
# A builtin the CHECKER admits must be lowered under the SPELLING it was
# admitted under (#2934, the 0.1.0-rc.0 bug hunt).
#
# `HostStream::close` and `host_stream_close` carry the same signature,
# `(HostStream) -> Unit`, and `checker/builtins_async.vibe` admits both. The
# default (non-linked) lane's dispatch in `codegen/expr/compile_call.vibe`
# carried only the bare one, so the two spellings of one operation answered
# differently -- measured on stage2 at c5afe4373:
#
#   host_stream_close(0)  -> host_stream_close: requires an Async-row entry ...
#   HostStream::close(0)  -> internal compiler error: `HostStream::close`
#                            (local, @call) reached code generation unresolved
#
# `vibe check` was CLEAN for both. That is the shape #2913 fixed for `map_has`
# and #2900 for four `Array::` names, and it is the worst kind of compiler
# failure to leave in a release candidate for a reason the second row shows:
# the message tells the reader it is a compiler bug and to report it, when what
# they wrote was a real operation that simply was not wired up.
#
# So this asserts the PROPERTY, not the fix: every spelling of the operation
# reaches the same lowering and explains itself. The bare spelling is the
# control -- it never regressed, so if it ever stops explaining itself the
# harness, not the fix, is what broke.
#
#   VIBE_CLI_WASM   the compiler to ask. Left unset, scripts/resolve_stage2.sh
#                   picks HEAD's generation and SAYS which one it picked --
#                   never silently, because the committed seed is a different
#                   compiler than a checkout's stage2.
#   VIBE_RUNNER     the viberun binary (default: the release build in-tree)
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# `resolve_stage2` is the CHECK resolver (HEAD's generation, else the newest on
# disk, else the committed seed, announcing each step): this is a check, and a
# check is usually better run against something than not run. An explicit
# VIBE_CLI_WASM still wins, which is what a before/after comparison uses.
. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 builtin-spelling "${VIBE_CLI_WASM:-}")" || exit 1
if [ -z "$CLI" ] || [ ! -f "$CLI" ]; then
  echo "builtin-spelling: no compiler to ask; set VIBE_CLI_WASM to a stage2" >&2
  exit 2
fi
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
if [ ! -x "$RUNNER" ]; then
  echo "builtin-spelling: no runner at $RUNNER (build it, or set VIBE_RUNNER)" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-builtin-spelling.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

probe() { # probe <call> -> CHECK_OUT, RUN_OUT
  printf 'fn main allows Console {\n  let _x = %s\n  println("ok")\n}\n' "$1" > "$WORK/p.vibex"
  CHECK_OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" timeout 300 \
    bash runtime/vibe check "$WORK/p.vibex" 2>&1)"
  RUN_OUT="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" timeout 400 \
    bash runtime/vibe run "$WORK/p.vibex" 2>&1)"
}

assert_lowered() { # assert_lowered <call>
  probe "$1"
  if printf '%s' "$RUN_OUT" | grep -qF "reached code generation unresolved"; then
    note "  FAIL $1: ICE -- admitted by the checker, lowered nowhere"
    printf '%s\n' "$RUN_OUT" | head -2 | sed 's/^/        /'
    fail=1
    return
  fi
  if ! printf '%s' "$RUN_OUT" | grep -qF "requires an Async-row entry"; then
    note "  FAIL $1: did not give the Async-row explanation"
    printf '%s\n' "$RUN_OUT" | head -2 | sed 's/^/        /'
    fail=1
    return
  fi
  # The message must name what the PROGRAM wrote. A diagnostic that renames the
  # call makes the reader reconcile two spellings before they can act.
  if ! printf '%s' "$RUN_OUT" | grep -qF "${1%%(*}: requires an Async-row entry"; then
    note "  FAIL $1: the message names a different spelling"
    printf '%s\n' "$RUN_OUT" | head -1 | sed 's/^/        /'
    fail=1
    return
  fi
  note "  ok   $1 is lowered and explains itself under its own name"
}

note "=== both spellings of the close operation reach the same lowering ==="
assert_lowered "HostStream::close(0)"
assert_lowered "host_stream_close(0)"

note "=== and the checker admitted both, which is why the above must hold ==="
# If a spelling ever stops type-checking this test would pass vacuously: the
# run output would carry a type error instead of an ICE, and "not an ICE" is
# not the property. So the admission is asserted separately.
for spelling in "HostStream::close(0)" "host_stream_close(0)"; do
  probe "$spelling"
  if [ -n "$CHECK_OUT" ]; then
    note "  FAIL $spelling: vibe check is no longer clean, so the rows above prove nothing"
    printf '%s\n' "$CHECK_OUT" | head -1 | sed 's/^/        /'
    fail=1
  else
    note "  ok   $spelling passes vibe check clean"
  fi
done

note
if [ "$fail" = 0 ]; then note "[builtin-spelling] ok"; else note "[builtin-spelling] FAIL"; fi
exit "$fail"
