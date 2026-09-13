#!/usr/bin/env bash
# #2737: a witness dispatch on a bound declared by a LAMBDA binder is refused,
# and the refusal names the edit.
#
# Only a TOP-LEVEL generic is threaded (`build_gens` / `thread_dict_params`).
# `rewrite_expr`'s EFn arm rebuilds a nested lambda with its bounds untouched and
# never extends `dict_binds`, so `[T: Eq]` on a lambda binder is accepted by the
# parser and by the checker -- which even suggests writing it (#2474) -- and then
# honoured by nothing.
#
# Left alone, the four rungs do not degrade into a worse answer; they produce
# undefined behaviour. Measured on main at 8f70aa1:
#
#   T::equals / a.equals   an unresolved name reaching codegen, lowered to a table
#                          call on a bogus index -- `true` with two impls in the
#                          program, `trap: null function or function signature
#                          mismatch` with three, so the answer was a function of
#                          the module's function-table layout
#   "\{a}"                 the erased representation -- `Pt!` through the enclosing
#                          binder's witness, and `284` (a tagged pointer) with that
#                          witness withheld
#
# So the refusal is not a diagnostic standing in for a working program. It is a
# diagnostic standing in for garbage.
#
# The MESSAGE is asserted and not merely the refusal: "did not compile" is
# satisfied by any unrelated breakage, which is how a gate ends up green about
# something it never saw. The green side is a separate, committed fixture
# (`fixtures/lambda_bound_toplevel_witness_test.vibe`, the same four rungs with
# the binder at the top level) running in the unit lane -- each condition here is
# one step from rejecting the shape the language DOES support, and a refusal that
# grew that wide would leave every assertion below passing.
#
# The fourth rung arrived from review (Codex, P1 on the first commit): a method
# taken as a VALUE (`let cmp = T::equals`) reaches the qualified EIdent arm rather
# than either call site, so two refusals at the call sites left it unrefused and
# still answering `true` for `equals(7, 8)`. The corpus is a GLOB for that reason
# -- a route found later joins by adding a file, not by editing this script.
#
# Round 2 added the KINDED case the same way. A formal declared `F[_]` is stored as
# `type_param_key(name, arity)` while every lookup passes a bare head, so the whole
# condition was blind to it and its nested dispatch died on a bare
# `trap: RuntimeError: unreachable`. Both rounds are the same shape of mistake: the
# condition was stated once and then applied through whatever spelling or arm
# happened to be in front of it.
set -euo pipefail
# Overridable ONLY so this gate's own self-test can run a MUTATED COPY of this
# script from a scratch directory -- the same escape hatch, for the same reason,
# as check_gate_self_tests.sh's VIBE_GATE_SELF_TEST_ROOT. Unset on every real
# invocation.
ROOT_DIR="${VIBE_LAMBDA_BOUND_REFUSAL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 lambda-bound-refusal "${LAMBDA_BOUND_REFUSAL_STAGE2:-}")" || exit 1

# Overridable so the self-test can point the gate at a mutated copy of the
# corpus instead of editing the tree's own fixtures.
FIXTURE_GLOB="${LAMBDA_BOUND_REFUSAL_FIXTURES:-fixtures/lambda_bound_dispatch_*_refused.vibe}"

WORK="$ROOT_DIR/_build/_lambda_bound_refusal"
rm -rf "$WORK"; mkdir -p "$WORK"

found=0
for src in $FIXTURE_GLOB; do
  [ -f "$src" ] || continue
  found=$((found + 1))
  name="$(basename "${src%.vibe}")"
  out="$WORK/$name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$src" "$out" _start >/dev/null 2>&1 || true
  if [ -s "$out" ]; then
    echo "[lambda-bound-refusal] FAIL: $src compiled; expected a compile-time refusal (#2737)" >&2
    exit 1
  fi
  if ! grep -qE 'cannot (dispatch|interpolate a value of type parameter)' "$out.diag" 2>/dev/null; then
    echo "[lambda-bound-refusal] FAIL: $src was refused without the #2737 message" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if ! grep -qF 'move the lambda to a top-level declaration' "$out.diag" 2>/dev/null; then
    echo "[lambda-bound-refusal] FAIL: $src refusal does not name an edit" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
done

# A glob that matches nothing must not pass. Silence is "unchecked", and the two
# are indistinguishable from the exit code (#2248).
if [ "$found" -eq 0 ]; then
  echo "[lambda-bound-refusal] FAIL: no fixtures matched $FIXTURE_GLOB" >&2
  exit 1
fi

echo "[lambda-bound-refusal] ok ($found fixtures refused with an actionable message)"
