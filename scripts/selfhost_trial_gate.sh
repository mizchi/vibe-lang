#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" != "--post-generation" ]; then
  echo "== selfhost gate: stage generation =="
  bash scripts/selfhost_generations.sh build --stage3
fi

echo "== selfhost gate: release selfhost gates =="
pkf run release-selfhost-gates

echo "== selfhost gate: corpus REAL-gap gate =="
bash scripts/test_selfhost_corpus_gate.sh --gate

echo "== selfhost gate: perf KPI =="
VIBE_SELFHOST_PERF_COMPILER_KIND=cli-core \
VIBE_SELFHOST_PERF_CHECKER_KIND=cli-core \
VIBE_SELFHOST_PERF_COMPILE_DAEMON=1 \
VIBE_SELFHOST_PERF_CHECK_DAEMON=1 \
VIBE_SELFHOST_PERF_RUNS=3 \
VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO=2.5 \
VIBE_SELFHOST_PERF_MAX_CHECK_RATIO=1.33 \
VIBE_SELFHOST_PERF_CASES_FILE=bench/selfhost_perf/kpi_cases.txt \
  scripts/bench_selfhost_perf.sh

echo "== selfhost gate: peak RSS KPI =="
VIBE_SELFHOST_RSS_MAX_RATIO=2.0 scripts/bench_selfhost_rss.sh --gate

echo "selfhost gate: ok"
