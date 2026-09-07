#!/usr/bin/env bash
# check_portable_boundary_test.sh -- red test for check_portable_boundary.sh.
#
# Written when that gate was repaired (#2577). It had been asserting a
# two-generations-old shape of the boundary -- `export let name: (...) -> Bytes
# with { Error }` in an `index.vibe` facade -- after ADR-0070 moved the contract
# to `index.vpkg` and ADR-0085 replaced `Error` with `Exception`. So it reported
# "missing expected pure boundary" for files that no longer existed, while every
# boundary it names was intact in the contract beside them. It runs in no CI
# job, so nothing said so.
#
# Repairing a gate that has been dark is exactly when it needs a red test:
# "it says ok now" is equally consistent with "it was fixed" and "it was
# neutered". These four cases separate those, and the two mutation cases are
# the ones the repair could plausibly have broken.
#
# The gate scans the repository from its own location rather than a tree it is
# handed, so each case mutates a real file and restores it with `git checkout`.
# The restore runs on EXIT, so an interrupted run does not leave the tree
# modified.
#
# #2252: no environment is inherited -- this gate reads none, and the test sets
# none.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

gate="scripts/check_portable_boundary.sh"
impl="lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe"
contract="lib/@vibe/compiler/entry/source_compile/index.vpkg"

# Refuse to run against a dirty tree: the restore below would discard the
# author's uncommitted work in these two files.
if ! git diff --quiet -- "$impl" "$contract"; then
  echo "portable-boundary-test: $impl or $contract has uncommitted changes." >&2
  echo "  This test mutates and restores them with 'git checkout'. Commit or" >&2
  echo "  stash first, so a restore cannot discard your work." >&2
  exit 2
fi

restore() { git checkout -q -- "$impl" "$contract" 2>/dev/null || true; }
trap restore EXIT

fails=0
pass() { printf 'portable-boundary-test: ok: %s\n' "$1"; }
fail() { printf 'portable-boundary-test: FAIL: %s\n' "$1" >&2; fails=1; }

# --- control, first: the unmutated tree passes -------------------------------
#
# Load-bearing. Three of the four cases assert a FAILURE, so a gate that
# rejected everything would make them all "pass" while proving nothing.

if bash "$gate" >/dev/null 2>&1; then
  pass "control: the unmutated tree passes"
else
  fail "control: the unmutated tree is rejected -- the red cases below prove nothing"
  bash "$gate" >&2 || true
fi

# --- case 1: a native capability in CODE is rejected -------------------------

printf '\nlet _portable_boundary_probe = perform Fs::read_file("x")\n' >> "$impl"
if bash "$gate" >/dev/null 2>&1; then
  fail "case 1: a 'perform Fs::read_file' in code passed"
else
  pass "case 1: a native capability in code is rejected"
fi
restore

# --- case 2: the same text in a COMMENT is accepted --------------------------
#
# The distinction the repair introduced, asserted rather than assumed. These
# files exist to explain how they differ from the FS lane, so prose naming a
# native entry point is the writing we want -- the gate was failing on
# "-- see `compile_file_fs_mode`'s comment, #2391". Case 1 is what keeps this
# from being a blanket exemption: strip comments, still catch code.

printf '\n/// prose naming perform Fs::read_file and compile_file_fs_mode\n' >> "$impl"
if bash "$gate" >/dev/null 2>&1; then
  pass "case 2: the same names in a comment are accepted"
else
  fail "case 2: a doc comment naming a native entry point was rejected as a leak"
fi
restore

# --- case 3: a boundary that gains an effect is rejected ---------------------
#
# The require_line half. `with Exception` becoming `with Fs` is the change this
# gate exists to catch, and it is the half that had rotted: it was matching a
# spelling no file in the tree had used for two ADRs.

sed 's/^fn compile_source(source: String) -> Bytes with Exception$/fn compile_source(source: String) -> Bytes with Fs/' \
  "$contract" > "$contract.probe"
mv "$contract.probe" "$contract"
if git diff --quiet -- "$contract"; then
  fail "case 3: the mutation did not land -- the assertion below would prove nothing"
else
  if bash "$gate" >/dev/null 2>&1; then
    fail "case 3: a boundary declaring 'with Fs' passed"
  else
    pass "case 3: a boundary that gains a native effect is rejected"
  fi
fi
restore

# --- case 4: an IMPLEMENTATION that declares a native effect row ------------
#
# The forbid_pattern half, which case 3 does NOT reach: case 3 edits the
# contract line, so require_line fails first and the gate's rejection says
# nothing about whether forbid_pattern recognizes the row syntax. It did not.
# Measured before the fix: appending this exact declaration left the gate
# printing `ok`, because native_effect_pattern only knew the braced
# `with { ... }` spelling -- which is the HANDLER syntax, not an effect row.
printf '\nexport fn probe_native() -> Unit with Fs {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_native\(\) -> Unit with Fs \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case 4: an implementation declaring 'with Fs' passed the gate"
  else
    pass "case 4: a native effect row in an implementation is rejected"
  fi
else
  fail "case 4: the mutation did not land -- the assertion below would prove nothing"
fi
restore

# --- case 5: a non-native effect row is still accepted -----------------------
#
# Case 4 alone is also satisfied by a matcher that rejects every `with` row, so
# this pins the other side: `with Exception` is what these boundaries are
# REQUIRED to carry, and must not start reading as a leak.
printf '\nexport fn probe_pure() -> Unit with Exception {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_pure\(\) -> Unit with Exception \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case 5: a non-native effect row is accepted"
  else
    fail "case 5: 'with Exception' was rejected as a native leak"
  fi
else
  fail "case 5: the mutation did not land -- the assertion above would prove nothing"
fi
restore

# --- cases 6-8: the allow-list rejects every non-portable capability --------
#
# `Fs` alone (case 4) is satisfied by a deny-list, which is what this gate had
# twice -- and both times it passed a capability nobody had thought to name.
# `Env` and `Console` are capability builtins (AGENTS.md) and both passed the
# Fs|Process|Socket|Net|Http matcher. `Nonsense` stands for the capability that
# does not exist yet: an allow-list must reject it without being taught to.
for eff in Env Console Nonsense; do
  printf '\nexport fn probe_%s() -> Unit with %s {\n  ()\n}\n' "$eff" "$eff" >> "$impl"
  if grep -qE "^export fn probe_$eff\(\) -> Unit with $eff \{$" "$impl"; then
    if bash "$gate" >/dev/null 2>&1; then
      fail "case: an implementation declaring 'with $eff' passed the gate"
    else
      pass "case: 'with $eff' is rejected by the allow-list"
    fi
  else
    fail "case: the 'with $eff' mutation did not land -- the assertion proves nothing"
  fi
  restore
done

# --- case 9: an allowed effect in a COMPOUND row is still accepted -----------
#
# The row splitter has to handle `A + B`, not just a bare effect. If it did not,
# every compound row would read as one unknown name and the gate would reject
# code it must accept -- a gate that fails closed on correct input gets
# disabled, which is the outcome #2252 describes.
printf '\nexport fn probe_compound() -> Unit with Exception + Async {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_compound\(\) -> Unit with Exception \+ Async \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    pass "case: a compound row of allowed effects is accepted"
  else
    fail "case: 'with Exception + Async' was rejected -- the row splitter is wrong"
  fi
else
  fail "case: the compound-row mutation did not land -- the assertion proves nothing"
fi
restore

# --- case 10: a native capability hidden in a compound row is caught ---------
#
# The converse of case 9, and the shape a real leak takes: the forbidden effect
# is not the first name in the row.
printf '\nexport fn probe_mixed() -> Unit with Exception + Fs {\n  ()\n}\n' >> "$impl"
if grep -qE '^export fn probe_mixed\(\) -> Unit with Exception \+ Fs \{$' "$impl"; then
  if bash "$gate" >/dev/null 2>&1; then
    fail "case: 'with Exception + Fs' passed -- only the first effect is checked"
  else
    pass "case: a native effect later in a compound row is rejected"
  fi
else
  fail "case: the mixed-row mutation did not land -- the assertion proves nothing"
fi
restore

if [ "$fails" -ne 0 ]; then
  echo "portable-boundary-test: FAILED" >&2
  exit 1
fi
echo "portable-boundary-test: ok (control + 10 cases)"
