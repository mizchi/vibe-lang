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
missing="$(awk '
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  /^[A-Za-z0-9_-]+:/ { if (!/^jobs:/) { if (job != "" && uses_scripts && !has_cache) print job; in_jobs = 0; job = "" } }
  !in_jobs { next }
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    if (job != "" && uses_scripts && !has_cache) print job
    job = $1; sub(/:$/, "", job)
    uses_scripts = 0; has_cache = 0
    next
  }
  job == "" { next }
  /bash[[:space:]]+scripts\// { uses_scripts = 1 }
  /bash[[:space:]]+tests\//   { uses_scripts = 1 }
  /pkf[[:space:]]+run/        { uses_scripts = 1 }
  /seed-artifact-/            { has_cache = 1 }
  END { if (job != "" && uses_scripts && !has_cache) print job }
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
if [ "$scanned" -lt 2 ]; then
  echo "[ci-seed-cache] FAIL: found $scanned job headers in $WORKFLOW -- the scan did not run" >&2
  exit 1
fi

if [ -n "$missing" ]; then
  echo "[ci-seed-cache] FAIL: jobs that run repository scripts with no seed cache:" >&2
  printf '  %s\n' $missing >&2
  echo "  Add, before the first step that touches the compiler:" >&2
  echo "      - name: Cache seed artifact" >&2
  echo "        uses: actions/cache@v4" >&2
  echo "        with:" >&2
  echo "          path: bootstrap/seed/compiler.wasm" >&2
  echo "          key: seed-artifact-\${{ hashFiles('bootstrap/seed.json') }}" >&2
  echo "      - name: Ensure seed artifact" >&2
  echo "        run: bash scripts/ensure_seed.sh" >&2
  echo "  Without it the job rebuilds the pinned seed from source (~5 min)" >&2
  echo "  whenever its release tag is not published." >&2
  exit 1
fi

echo "[ci-seed-cache] ok ($scanned jobs scanned)"
