#!/usr/bin/env bash
# #2745 / #2840: interpolating a formal that is ERASED here is refused, and the
# refusal names the edit.
#
# ## The #2737 dispatch family is GONE, and that is the point
#
# This gate was born holding two families. The first was #2737: a witness
# dispatch on a bound declared by a LAMBDA binder, refused because only a
# TOP-LEVEL generic was threaded -- `rewrite_expr`'s EFn arm rebuilt a nested
# lambda with its bounds untouched, so `[T: Eq]` on a lambda binder was accepted
# by the parser and by the checker (which even suggests writing it, #2474) and
# then honoured by nothing. Those rungs did not degrade into a worse answer;
# they produced undefined behaviour. Measured on main at 8f70aa1, `T::equals`
# reached codegen as an unresolved name lowered to a table call on a bogus
# index: `true` with two impls in the program, `trap: null function or function
# signature mismatch` with three -- the answer was a function of the module's
# function-table layout.
#
# #2778 threaded them. The EFn arm now overlays a nested binder's own
# dictionaries on the enclosing ones, so every rung of that family became a
# WORKING program and its fixtures left one at a time, the last of them
# (the shadowed spelling) once its answer was measured. Their green side is
# `fixtures/lambda_bound_nested_witness_test.vibe`, which pins the answers.
#
# A family emptying out is the intended end state for a gate like this, not a
# hole in it: what it guarded is now a language feature with tests. The `*)`
# arm below is what keeps that honest -- a fixture whose name matches the glob
# but no family FAILS rather than being waved through, so #2737's family cannot
# quietly come back unchecked, and a future third family cannot join unnamed.
#
# ## What is still guarded
#
# Interpolating a value whose type is a formal with no method-bearing renderer
# bound printed the tagged pointer (`272`) rather than the value. Threading did
# not fix that one and could not: a top-level generic body is not specialized,
# so there is no witness to reach however the binders nest. Its edit asks for an
# explicit renderer (#2840).
#
# The MESSAGE is asserted and not merely the refusal: "did not compile" is
# satisfied by any unrelated breakage, which is how a gate ends up green about
# something it never saw. The green side is a separate, committed fixture
# (`fixtures/lambda_bound_toplevel_witness_test.vibe`, the same rungs with the
# binder at the top level) running in the unit lane -- each condition here is one
# step from rejecting the shape the language DOES support, and a refusal that
# grew that wide would leave every assertion below passing.
#
# The corpus is a GLOB because routes keep being found later, and each arrived
# the same way: the condition was stated once and then applied through whatever
# spelling or arm happened to be in front of it. A method taken as a VALUE
# (`let cmp = T::equals`) reached the qualified EIdent arm rather than either
# call site (Codex, P1 on the first commit). A formal declared `F[_]` is stored
# as `type_param_key(name, arity)` while every lookup passed a bare head, so the
# whole condition was blind to it. A route found later joins by adding a file,
# not by editing this script.
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
FIXTURE_GLOB="${LAMBDA_BOUND_REFUSAL_FIXTURES:-fixtures/lambda_bound_*_refused.vibe}"

# The reason clause, chosen from the fixture's NAME rather than accepted from
# whatever the compiler happened to say. Accepting any refusal would pass a
# fixture refused by the wrong rule, which is the same proxy-instead-of-property
# mistake this gate has already made once. One family is left, so this is one
# row; the `*)` arm below is what makes adding a second row mandatory rather
# than optional.
erased_reason="is erased here"

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
  # Classified BEFORE the refusal test, so the "it compiled" failure can name the
  # fixture's own issue. It named #2737 for every family, which is wrong for the
  # 23 erased-interpolation fixtures and sends a reader to the wrong thread.
  case "$name" in
    lambda_bound_erased_interp_*) reason="$erased_reason"; issue="#2745"; edit="pass an explicit renderer" ;;
    *)
      echo "[lambda-bound-refusal] FAIL: $src matches the glob but no family" >&2
      echo "  add its reason clause here; an unclassified fixture is unchecked, not clean" >&2
      echo "  (#2737's lambda_bound_dispatch_* family was retired by #2778 -- those" >&2
      echo "   shapes compile now; their answers live in lambda_bound_nested_witness_test.vibe)" >&2
      exit 1
      ;;
  esac
  if [ -s "$out" ]; then
    echo "[lambda-bound-refusal] FAIL: $src compiled; expected a compile-time refusal ($issue)" >&2
    exit 1
  fi
  if ! grep -qF "$reason" "$out.diag" 2>/dev/null; then
    echo "[lambda-bound-refusal] FAIL: $src was refused without the $issue message" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  if [ "$issue" = "#2745" ] && ! grep -qE 'pass an explicit renderer .* interpolate at a concrete type' "$out.diag" 2>/dev/null; then
    echo "[lambda-bound-refusal] FAIL: $src refusal does not name an edit" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  # AGENTS.md: a diagnostic LEADS with the edit that fixes it.
  #
  # Asserting that both clauses are merely PRESENT passes on a message that buries
  # the edit behind the reason -- which is what this one did until Codex round 3 on
  # #2746. The first attempt at fixing that asserted the edit appears BEFORE the
  # word "has no", and Codex round 4 on #2753 pointed out that this is a proxy too:
  # `cannot dispatch ...; move the lambda binding ...: T::equals has no witness`
  # satisfies it while leading with the failure. That is #2248's rule about gates
  # exactly -- its finding was that each broken gate had trusted a PROXY rather
  # than the property itself -- landing on a gate written to enforce a different
  # instance of the same rule.
  #
  # So the property itself: the payload BEGINS with the edit. An optional
  # `<path>:` prefix is stripped first -- this lane's diag carries none, but a lane
  # that adds one must not silently turn "begins with" into "contains".
  leads_ok="$(awk -v edit="$edit" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/^[^[:space:]]*\.vibe[^[:space:]]*:[[:space:]]*/, "", line)
      if (index(line, edit) == 1) { print "ok"; exit }
    }
  ' "$out.diag" 2>/dev/null || true)"
  if [ "$leads_ok" != "ok" ]; then
    echo "[lambda-bound-refusal] FAIL: $src refusal does not BEGIN with the edit" >&2
    echo "  AGENTS.md: a diagnostic leads with the edit that fixes it, then the reason" >&2
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

echo "[lambda-bound-refusal] ok ($found fixtures refused with an actionable message, edit first)"
