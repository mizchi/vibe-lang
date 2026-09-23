#!/usr/bin/env bash
# warm_pkl_package_cache.sh -- fetch the Pkl packages Taskfile.pkl amends,
# with retries, before anything else asks pkf a question.
#
# pkf (the MoonBit build, 0.16+) resolves `amends "package://…pkfire@X#/…"`
# at EVALUATION time and downloads the package zip from GitHub into
# ~/.cache/pkl-mbt/package-2. With no cache that download happens inside
# whichever step first runs `pkf`, and a transient network error there is
# reported as that step's failure. Measured on CI run 35916386839: the
# selftests lane's check_task_env_sanitized_test.sh failed its green control
# with
#
#   pkf: evaluate …/Taskfile.pkl: zip fetch failed: …/pkfire@0.14.2.zip
#   http fetch failed: NetworkError("InvalidUrl(\"https://github.com\")")
#
# on a docs-only change, while the runs on either side of it passed. The gate
# was right to refuse (it could not ask its question); the defect was that a
# one-off download was on the critical path of a correctness check.
#
# This script moves the download to setup, retries it, and then checks the
# PROPERTY -- the package directory exists -- rather than pkf's exit status
# alone. The package is immutable per version, so the directory is also safe
# to cache across runs. That is different from ~/.cache/pkfire-mbt, the task
# output cache, which check_task_env_sanitized.sh must never read from.
#
# Usage: bash scripts/warm_pkl_package_cache.sh
#   PKL_WARM_ATTEMPTS  number of attempts (default 4)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

attempts="${PKL_WARM_ATTEMPTS:-4}"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/pkl-mbt/package-2"

# The package the Taskfile amends, e.g. `github.com/mizchi/pkfire/pkfire@0.14.2`.
# Read with sed rather than a pipeline into `grep -q`: under pipefail an early
# grep exit can SIGPIPE the producer and turn a match into a failure.
pkg="$(sed -n 's|^amends "package://pkg\.pkl-lang\.org/\([^#"]*\)#.*|\1|p' Taskfile.pkl | head -n 1)"
if [ -z "$pkg" ]; then
  echo "[pkl-warm] FAIL: no \`amends \"package://pkg.pkl-lang.org/…\"\` line in Taskfile.pkl" >&2
  echo "  The package this script is meant to fetch is not where it looked; fix the pattern." >&2
  exit 1
fi
want="$cache_root/$pkg"

delay=2
i=1
while :; do
  if pkf list >/dev/null 2>"${TMPDIR:-/tmp}/pkl-warm.err.$$" && [ -d "$want" ]; then
    rm -f "${TMPDIR:-/tmp}/pkl-warm.err.$$"
    echo "[pkl-warm] ok: $pkg cached (attempt $i)"
    exit 0
  fi
  if [ "$i" -ge "$attempts" ]; then
    echo "[pkl-warm] FAIL: could not fetch $pkg after $attempts attempts" >&2
    cat "${TMPDIR:-/tmp}/pkl-warm.err.$$" >&2 || true
    rm -f "${TMPDIR:-/tmp}/pkl-warm.err.$$"
    exit 1
  fi
  echo "[pkl-warm] attempt $i failed; retrying in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
  i=$((i + 1))
done
