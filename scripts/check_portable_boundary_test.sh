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

if [ "$fails" -ne 0 ]; then
  echo "portable-boundary-test: FAILED" >&2
  exit 1
fi
echo "portable-boundary-test: ok (control + 3 cases)"
