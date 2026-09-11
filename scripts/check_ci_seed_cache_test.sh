#!/usr/bin/env bash
# Red test for scripts/check_ci_seed_cache.sh (#2645).
#
# Every case MUTATES a real input and asserts the gate FAILS, and every
# mutation is verified to have landed before the gate is asked -- an edit that
# matched nothing would let a case "pass" while proving nothing (the failure
# mode docs/… calls out: a multi-line slice that only caught the first line).
set -euo pipefail

# Do not inherit the answer: the gate reads these, so a value left in the
# environment by a caller would decide the result instead of the input.
unset VIBE_CI_SEED_CACHE_ROOT
unset VIBE_CI_SEED_CACHE_WORKFLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/check_ci_seed_cache.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ci_seed_cache_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "check_ci_seed_cache_test: FAIL: $*" >&2; exit 1; }

# --- control: the real workflow passes ---------------------------------------
if ! bash "$GATE" >"$TMP/control.out" 2>&1; then
  cat "$TMP/control.out" >&2
  fail "control: the repository's own ci.yml is rejected"
fi
echo "check_ci_seed_cache_test: ok: control: the real workflow passes"

# --- case 1: a script-running job whose seed cache was removed is rejected ----
# Mutate the REAL workflow, not a synthetic one, so the gate is exercised
# against the shape it actually has to read.
real="$ROOT_DIR/.github/workflows/ci.yml"
awk '
  /seed-artifact-/ && !done_one && job_is_gate { next }
  /^  unit-tests:[[:space:]]*$/ { job_is_gate = 1 }
  /^  coverage-suite:[[:space:]]*$/ { job_is_gate = 0 }
  { print }
' "$real" > "$TMP/mutated.yml"
# The mutation must have landed: strictly fewer seed keys than the original.
before="$(grep -c 'seed-artifact-' "$real" || true)"
after="$(grep -c 'seed-artifact-' "$TMP/mutated.yml" || true)"
[ "$after" -lt "$before" ] || fail "case 1: the mutation did not land ($before -> $after seed keys)"
if VIBE_CI_SEED_CACHE_WORKFLOW="$TMP/mutated.yml" bash "$GATE" >"$TMP/case1.out" 2>&1; then
  fail "case 1: a job that runs repository scripts with no seed cache was accepted"
fi
grep -q 'unit-tests' "$TMP/case1.out" || fail "case 1: the message does not name the offending job"
grep -q 'Cache seed artifact' "$TMP/case1.out" || fail "case 1: the message does not name the edit that fixes it"
echo "check_ci_seed_cache_test: ok: case 1: a script-running job with no seed cache is rejected"

# --- case 2: `pkf run` counts as reaching the seed ----------------------------
cat > "$TMP/pkf.yml" <<'YML'
name: CI
on:
  push:
jobs:
  needs-seed:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Task runner
        run: pkf run release-check
YML
if VIBE_CI_SEED_CACHE_WORKFLOW="$TMP/pkf.yml" bash "$GATE" >"$TMP/case2.out" 2>&1; then
  fail "case 2: a 'pkf run' job with no seed cache was accepted"
fi
echo "check_ci_seed_cache_test: ok: case 2: 'pkf run' counts as reaching the seed"

# --- case 3: a job that runs no repository script is NOT a false positive -----
cat > "$TMP/inert.yml" <<'YML'
name: CI
on:
  push:
jobs:
  aggregate:
    runs-on: ubuntu-latest
    steps:
      - name: Verify required jobs succeeded
        run: echo "all required jobs passed"
  needs-seed:
    runs-on: ubuntu-latest
    steps:
      - name: Cache seed artifact
        uses: actions/cache@v4
        with:
          key: seed-artifact-abc
      - name: Build
        run: bash scripts/ensure_seed.sh
YML
if ! VIBE_CI_SEED_CACHE_WORKFLOW="$TMP/inert.yml" bash "$GATE" >"$TMP/case3.out" 2>&1; then
  cat "$TMP/case3.out" >&2
  fail "case 3: a job that runs no repository script was rejected"
fi
echo "check_ci_seed_cache_test: ok: case 3: a job that runs no repository script passes"

# --- case 4: an unreadable shape REFUSES instead of passing -------------------
# Silence is not safety: a workflow the scan cannot parse must fail, not read
# as "no offending jobs".
printf 'name: CI\non:\n  push:\n' > "$TMP/nojobs.yml"
if VIBE_CI_SEED_CACHE_WORKFLOW="$TMP/nojobs.yml" bash "$GATE" >"$TMP/case4.out" 2>&1; then
  fail "case 4: a workflow with no jobs at all was accepted"
fi
grep -q 'the scan did not run' "$TMP/case4.out" || fail "case 4: the refusal does not say the scan did not run"
echo "check_ci_seed_cache_test: ok: case 4: an unscannable workflow refuses to answer"

# --- case 5: a missing workflow is fatal --------------------------------------
if VIBE_CI_SEED_CACHE_WORKFLOW="$TMP/does-not-exist.yml" bash "$GATE" >/dev/null 2>&1; then
  fail "case 5: a missing workflow was accepted"
fi
echo "check_ci_seed_cache_test: ok: case 5: a missing workflow is fatal"

echo "check_ci_seed_cache_test: ok (control + 5 cases)"
