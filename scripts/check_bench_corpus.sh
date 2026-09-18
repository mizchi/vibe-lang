#!/usr/bin/env bash
# #2865: a benchmark's INPUT must not be a file that PRs edit.
#
# The lex and parse series read the live compiler sources, so a PR that touched
# the checker moved the input of the benchmark that measures the parser.
# Measured on one compiler with only the corpus swapped, across a checker PR
# that grew `checker.vibe` 9.7%: `parse_checker_vibe` went 4,926,112 ->
# 5,780,608 B/op (+17.3%). The perf report flags that with a warning, and a
# reviewer acts on it. Every checker PR of any size tripped it, and a real
# parser regression landing beside a checker edit was indistinguishable from
# corpus growth.
#
# Two properties, because pinning the corpus and leaving it pinned are
# different things:
#
#   1. Every snapshot matches the digest PROVENANCE.tsv records. A frozen
#      corpus is rewritten by scripts/bump_bench_corpus.sh, which rewrites the
#      banner and the digest TOGETHER, and by nothing else. An edit that skips
#      it silently restates every number in the series.
#   2. No bench or hotspot probe under lib/ names a live `lib/**.vibe` path as
#      its corpus, unless it is on the allow-list with a reason.
#
# The allow-list is the decision surface: a bench whose subject IS the live tree
# (the loader resolves a real import closure, which a frozen copy cannot stand
# in for) says so there, and a bench that simply has not been pinned yet says
# THAT there, with an issue number. Silence is neither.
#
# Usage:
#   bash scripts/check_bench_corpus.sh
set -euo pipefail
ROOT_DIR="${VIBE_BENCH_CORPUS_GATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

ALLOWLIST="${VIBE_BENCH_CORPUS_ALLOWLIST:-bench/perf/corpus/ALLOWLIST.txt}"
BENCH_GLOBS="${VIBE_BENCH_CORPUS_GLOBS:-lib/@vibe/compiler/*_bench.vibe lib/@vibe/compiler/*_probe.vibe}"

# 1. digests
bash "$ROOT_DIR/scripts/bump_bench_corpus.sh" --check

# 2. live-path corpora
if [ ! -f "$ALLOWLIST" ]; then
  echo "[bench-corpus] FAIL: missing $ALLOWLIST (an absent allow-list is not an empty one)" >&2
  exit 1
fi

allowed=""
while IFS= read -r line; do
  case "$line" in ""|\#*) continue ;; esac
  entry_path="${line%%	*}"
  entry_reason="${line#*	}"
  if [ "$entry_reason" = "$line" ] || [ -z "$entry_reason" ]; then
    echo "[bench-corpus] FAIL: allow-list row with no reason: $entry_path" >&2
    echo "  A row here is a written admission that a bench reads an input PRs edit; say why." >&2
    exit 1
  fi
  if [ ! -f "$entry_path" ]; then
    echo "[bench-corpus] FAIL: allow-list names a file that does not exist: $entry_path" >&2
    echo "  A stale row exempts nothing and hides that the corpus moved." >&2
    exit 1
  fi
  allowed="$allowed $entry_path"
done < "$ALLOWLIST"

scanned=0
bad=0
for f in $BENCH_GLOBS; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  case " $allowed " in *" $f "*) continue ;; esac
  hits="$(grep -n '"lib/[^"]*\.vibe"' "$f" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "[bench-corpus] FAIL: $f names a LIVE source path as a bench corpus (#2865)" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    bad=1
  fi
done

if [ "$scanned" -eq 0 ]; then
  # Silence is "unchecked", not "clean".
  echo "[bench-corpus] FAIL: no bench files matched $BENCH_GLOBS" >&2
  exit 1
fi

if [ "$bad" != 0 ]; then
  echo "  Read bench/perf/corpus/ instead, or add a row to $ALLOWLIST saying why not." >&2
  exit 1
fi

echo "[bench-corpus] ok ($scanned bench file(s) scanned, digests verified)"
