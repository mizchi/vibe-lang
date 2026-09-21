#!/usr/bin/env bash
# Red test for scripts/check_fuzz_compiler_identity.sh (#2248: a gate means
# nothing until it is shown to FAIL).
#
# Each case mutates a COPY of the real harness and asserts the gate rejects it.
# Every mutation is first checked to have CHANGED the file -- an edit that
# matches nothing passes the gate while proving nothing, which is how a red
# test certifies a hole instead of closing it.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
GATE="scripts/check_fuzz_compiler_identity.sh"
REAL="tests/fuzz/run_fuzz.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" tests/fuzz/.probe_*.sh' EXIT
rc_total=0
say() { printf '%s\n' "$*"; }
bad() { say "  FAIL $*"; rc_total=1; }

# Stage a mutated harness where the gate will look for it. The gate takes
# $FUZZ_HARNESS so a case never has to edit the tree it is checking.
#
# The copy has to live NEXT TO the real harness: run_fuzz.sh derives the
# repository root as `dirname "$0"/../..`, so a copy under /tmp resolves ROOT
# to `/` and dies sourcing `//scripts/resolve_stage2.sh`. That looked like a
# passing red test -- nonzero exit, a gate message -- while testing the
# staging path instead of the mutation. Same class of proxy failure the gate
# itself is about.
stage() { # <name> <sed-script>
  local name="$1"
  local script="$2"
  local dst="tests/fuzz/.probe_$name.sh"
  cp "$REAL" "$dst"
  sed -i.bak "$script" "$dst" && rm -f "$dst.bak"
  if cmp -s "$REAL" "$dst"; then
    bad "$name: the mutation changed nothing -- it would pass while proving nothing"
    return 1
  fi
  printf '%s\n' "$dst"
}

expect_fail() { # <name> <staged path>
  local name="$1" path="$2" out rc
  out="$(FUZZ_HARNESS="$path" bash "$GATE" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$name: gate ACCEPTED the mutation"
    return
  fi
  case "$out" in
    *check-fuzz-compiler-identity:*) say "  ok   $name: rejected -- $(printf '%s' "$out" | head -1)" ;;
    *) bad "$name: nonzero exit but no gate message: $(printf '%s' "$out" | head -1)" ;;
  esac
}

say "=== green: the real harness passes ==="
out="$(bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && say "  ok   $out" || bad "the real harness is rejected: $out"

say "=== red 1: back to picking the newest generation by mtime ==="
if p="$(stage mtime 's|^CLI="$(resolve_stage2_strict fuzz "$CLI")" .*$|CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null \| head -1)"|')"; then
  expect_fail mtime "$p"
else
  bad "mtime: could not be staged, so the case did not run"
fi

say "=== red 2: the LENIENT resolver, which degrades to the seed ==="
if p="$(stage lenient 's|resolve_stage2_strict fuzz|resolve_stage2 fuzz|')"; then
  expect_fail lenient "$p"
else
  bad "lenient: could not be staged, so the case did not run"
fi

say "=== red 3: the resolver is never sourced ==="
if p="$(stage unsourced 's|^\. "$ROOT/scripts/resolve_stage2\.sh"$|: # not sourced|')"; then
  expect_fail unsourced "$p"
else
  bad "unsourced: could not be staged, so the case did not run"
fi

say "=== red 4: a missing named artifact is accepted instead of refused ==="
# Behavioural only: the lexical checks still pass, so this case fails the gate
# ONLY if the second half actually runs the harness.
if p="$(stage lax 's|^CLI="$(resolve_stage2_strict fuzz "$CLI")" .*$|CLI="$(resolve_stage2_strict fuzz "$CLI")" \|\| CLI=bootstrap/seed/compiler.wasm|')"; then
  expect_fail lax "$p"
else
  bad "lax: could not be staged, so the case did not run"
fi

say "=== red 6: strict resolution present, but an mtime pick left beside it ==="
# Red 1 is rejected by the missing-strict-call check, so the mtime check never
# gets to speak there. This case keeps the strict call and adds the old pick
# back, which is the only way to see the mtime rule fire on its own.
if p="$(stage mtime_beside 's|^CLI="$(resolve_stage2_strict fuzz "$CLI")" .*$|&\nCLI="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null \| head -1)"|')"; then
  expect_fail mtime_beside "$p"
else
  bad "mtime_beside: could not be staged, so the case did not run"
fi

say "=== red 5: the gate refuses a harness that is not there at all ==="
out="$(FUZZ_HARNESS="tests/fuzz/.probe_absent.sh" bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && say "  ok   absent: rejected -- $(printf '%s' "$out" | head -1)" || bad "absent: gate ACCEPTED a missing harness"

if [ "$rc_total" -eq 0 ]; then
  say ""
  say "[fuzz-compiler-identity-test] ok"
else
  say ""
  say "[fuzz-compiler-identity-test] FAILED"
fi
exit "$rc_total"
