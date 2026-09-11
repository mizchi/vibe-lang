#!/usr/bin/env bash
# Every CI job that can reach the seed restores it from cache first (#2645).
#
# bootstrap/seed/compiler.wasm is gitignored, so the first thing in a job that
# touches the compiler calls scripts/ensure_seed.sh. That call is not cheap in
# the one case nobody watches: when the pinned release tag is not published yet
# (a bootstrap bump whose `seed-release` run has not landed), ensure_seed
# REBUILDS the pinned seed from source -- stage0 -> stage1 -> stage2 -- and
# does it inside whatever step asked first, with no step name to blame.
#
# Measured on CI run 34567587111 (main, 893s wall): four jobs had no seed
# cache and each paid the same ~5 minutes for the same artifact --
#   compiler-stage2-oracles  304s  charged to "Generated compiler fingerprint"
#   compiler-playground      323s  same step
#   compiler-docs            335s  same step
#   structural-lint          429s  charged to a shell lint's self-test
# -- while the twelve jobs that did have the cache restored it in ~2s.
#
# The rule is lexical so it can be checked: a job block that invokes a
# repository script (`bash scripts/...`, `bash tests/...`) or the task runner
# (`pkf run`) must also contain a `seed-artifact-` cache key. Which script it
# is does not matter; the dependency is transitive (scripts/vibe_run.sh,
# scripts/vibe_test.sh and scripts/ensure_generated.sh all call ensure_seed)
# and a scanner cannot follow it, so the over-approximation is the point --
# it costs a job that needs no seed one cache-miss lookup, and it makes the
# expensive mistake impossible.
set -euo pipefail

ROOT_DIR="${VIBE_CI_SEED_CACHE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"

WORKFLOW="${VIBE_CI_SEED_CACHE_WORKFLOW:-.github/workflows/ci.yml}"
if [ ! -f "$WORKFLOW" ]; then
  echo "[ci-seed-cache] FAIL: no workflow at $WORKFLOW" >&2
  exit 1
fi

# Split into job blocks: a job header is exactly two spaces of indent at the
# top level of `jobs:`. awk, not a YAML parser, because the property being
# checked is textual and the gate must run with nothing installed.
# ORDER MATTERS, not mere presence (Codex review of #2645). A job whose first
# script invocation comes BEFORE its cache step has already paid the fetch --
# or the ~5 minute rebuild -- by the time the cache is restored, and a
# presence-only check calls that clean. So the violation is recorded at the
# first script line seen while `has_cache` is still 0, and a later
# `seed-artifact-` cannot retract it.
missing="$(awk '
  function flush() { if (job != "" && bad) print job }
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  /^[A-Za-z0-9_-]+:/ { if (!/^jobs:/) { flush(); in_jobs = 0; job = "" } }
  !in_jobs { next }
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    flush()
    job = $1; sub(/:$/, "", job)
    bad = 0; has_cache = 0
    next
  }
  job == "" { next }
  # The cache line is read FIRST on its own line, so a step that both restores
  # the cache and runs a script on later lines is still ordered correctly.
  /seed-artifact-/ { has_cache = 1; next }
  /bash[[:space:]]+scripts\// || /bash[[:space:]]+tests\// || /pkf[[:space:]]+run/ {
    if (!has_cache) bad = 1
  }
  END { flush() }
' "$WORKFLOW")"

# Refuse to answer rather than pass when the scan found no jobs at all: an
# empty result and "every job is fine" are the same output otherwise, and a
# renamed file or a reindented workflow would read as clean forever.
scanned="$(awk '
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  /^[A-Za-z0-9_-]+:/ { if (!/^jobs:/) in_jobs = 0 }
  in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { n++ }
  END { print n + 0 }
' "$WORKFLOW")"
# One job is a legitimate workflow; ZERO means the scan found nothing, which is
# the case that must not read as "no offending jobs". (The threshold was 2 and
# refused a single-job workflow -- caught by this gate's own Red test.)
if [ "$scanned" -lt 1 ]; then
  echo "[ci-seed-cache] FAIL: found $scanned job headers in $WORKFLOW -- the scan did not run" >&2
  exit 1
fi

if [ -n "$missing" ]; then
  echo "[ci-seed-cache] FAIL: jobs that run a repository script before restoring the seed:" >&2
  printf '  %s\n' $missing >&2
  echo "  Add, before the first step that touches the compiler:" >&2
  echo "      - name: Cache seed artifact" >&2
  echo "        uses: actions/cache@v4" >&2
  echo "        with:" >&2
  echo "          path: bootstrap/seed/compiler.wasm" >&2
  echo "          key: seed-artifact-\${{ hashFiles('bootstrap/seed.json') }}" >&2
  echo "      - name: Ensure seed artifact" >&2
  echo "        run: bash scripts/ensure_seed.sh" >&2
  echo "  It must come BEFORE the first step that runs a repository script:" >&2
  echo "  by the time a later cache step restores it, the script has already" >&2
  echo "  fetched -- or rebuilt from source, ~5 min -- the pinned seed." >&2
  exit 1
fi

echo "[ci-seed-cache] ok ($scanned jobs scanned)"
