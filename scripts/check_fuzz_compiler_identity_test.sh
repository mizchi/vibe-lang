#!/usr/bin/env bash
# Red test for scripts/check_fuzz_compiler_identity.sh (#2248: a gate means
# nothing until it is shown to FAIL).
#
# Each case mutates a COPY of the real harness and asserts the gate rejects it.
# Every mutation is first checked to have CHANGED the file -- an edit that
# matches nothing passes the gate while proving nothing, which is how a red
# test certifies a hole instead of closing it.
set -uo pipefail
# A gate must not assume the environment it runs in (#2252). `FUZZ_JOBS` is
# read by run_fuzz.sh and validated before anything this file tests: exported
# as `0` or a non-number by a developer or a runner, every probe would exit at
# job-count validation and the gate would fail for ambient configuration
# rather than for its subject. Cleared here, and each probe passes `--jobs 1`
# explicitly so the value is this file's choice rather than an inheritance.
unset FUZZ_JOBS
cd "$(dirname "$0")/.."
ROOT="$PWD"
GATE="scripts/check_fuzz_compiler_identity.sh"
REAL="tests/fuzz/run_fuzz.sh"

# Every temporary allocation is CHECKED, and checked IN THIS SHELL. `set -uo
# pipefail` carries no `-e`, so a failed `mktemp -d` -- an inherited TMPDIR
# that is unwritable or missing -- leaves the variable EMPTY and the script
# running; `${VIBE_FUZZ_ROOT:-...}` in run_fuzz.sh triggers on empty as well as
# unset, so the probes would fall back to the shared `_build/fuzz` this
# isolation exists to protect (#2955 review).
#
# The first attempt put the abort in a function called as `V="$(f)"`, where
# `exit 1` ends the SUBSHELL and the parent carries on with V empty -- the
# guard printed its refusal and changed nothing, and a planted finding in the
# shared directory was still destroyed. So the check is inline at each site.
need_dir() { # <var-value> <what>
  if [ -z "${1:-}" ] || [ ! -d "${1:-}" ]; then
    printf '%s: could not allocate a temporary %s (TMPDIR=%s)
' "$(basename "$0")" "$2" "${TMPDIR:-unset}" >&2
    printf '%s: refusing to run -- the probes would fall back to the shared _build/fuzz
' "$(basename "$0")" >&2
    return 1
  fi
}

WORK="$(mktemp -d 2>/dev/null || true)"
need_dir "${WORK:-}" "work dir" || exit 1
# Isolated fuzz workspace. Two of the cases below mutate the harness so that it
# PROCEEDS past resolution, and a proceeding harness resets its findings
# directory -- against the shared `_build/fuzz/findings` that would delete a
# developer's campaign output whenever this gate ran. Measured: before this,
# a planted `seed_88_USER` finding did not survive the run (#2955 review named
# the sibling test; the same hole was here).
export VIBE_FUZZ_ROOT="$(mktemp -d 2>/dev/null || true)"
need_dir "${VIBE_FUZZ_ROOT:-}" "fuzz root" || exit 1
# Probes are PID-scoped and the cleanup names only its own. The trap used to
# glob `tests/fuzz/.probe_*.sh`, which also matched the probe
# tests/fuzz/stale_findings_test.sh stages -- under `release-check` the two
# run as sibling deps, so this cleanup could delete that file between its `cp`
# and its `bash`, failing a required gate for an unrelated missing file
# (#2955 review). They must live beside run_fuzz.sh, which derives the repo
# root from its own dirname, so uniqueness is by name rather than by
# directory.
PROBE_PREFIX="tests/fuzz/.probe_id$$_"
cleanup_probes() { rm -rf "$WORK" "$VIBE_FUZZ_ROOT" "$PROBE_PREFIX"*.sh; }
trap cleanup_probes EXIT
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
  local dst="$PROBE_PREFIX$name.sh"
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

say "=== red 7: proceeds after the refusal, and exits NONZERO doing it ==="
# The case CI caught and this test did not. Red 4's mutant falls back to the
# committed seed: where the seed exists it fuzzes it and exits 0, which the old
# exit-code check flagged -- but on a runner without one it died nonzero, and
# "nonzero exit, refusal text present" was satisfied by a harness that had
# started a run against something nobody chose. This mutant falls back to a
# path that exists NOWHERE, so it proceeds and exits nonzero on every machine.
# The gate must reject it for announcing the run, not for its exit code.
if p="$(stage proceeds_nonzero 's|^CLI="$(resolve_stage2_strict fuzz "$CLI")" .*$|CLI="$(resolve_stage2_strict fuzz "$CLI")" \|\| CLI=/nonexistent/fallback.wasm|')"; then
  expect_fail proceeds_nonzero "$p"
else
  bad "proceeds_nonzero: could not be staged, so the case did not run"
fi

say "=== red 5: the gate refuses a harness that is not there at all ==="
out="$(FUZZ_HARNESS="${PROBE_PREFIX}absent.sh" bash "$GATE" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && say "  ok   absent: rejected -- $(printf '%s' "$out" | head -1)" || bad "absent: gate ACCEPTED a missing harness"

if [ "$rc_total" -eq 0 ]; then
  say ""
  say "[fuzz-compiler-identity-test] ok"
else
  say ""
  say "[fuzz-compiler-identity-test] FAILED"
fi
exit "$rc_total"
