#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="${CLI_BIN:-$ROOT_DIR/_build/native/release/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/_build/bench/selfhost_cache_probe}"
RUNS="${VIBE_CACHE_PROBE_RUNS:-5}"
WARMUP="${VIBE_CACHE_PROBE_WARMUP:-1}"
BACKEND="${VIBE_CACHE_PROBE_BACKEND:-compiled}"

mkdir -p "$OUT_DIR"

if [[ ! -x "$CLI_BIN" ]]; then
  echo "bench-selfhost-cache-probe: missing CLI_BIN: $CLI_BIN" >&2
  exit 1
fi

cmd_multi_dep="VIBE_TEST_BACKEND=$BACKEND \"$CLI_BIN\" test \"$ROOT_DIR/lib/@vibe/compiler/tests/cache_probe_type_db_fs_multi_dep_bench_test.vibe\" >/dev/null"
cmd_cli_prepare="VIBE_TEST_BACKEND=$BACKEND \"$CLI_BIN\" test \"$ROOT_DIR/lib/@vibe/compiler/tests/cache_probe_cli_prepare_batch_bench_test.vibe\" >/dev/null"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$OUT_DIR/selfhost_cache_probe.json" \
    -n "type-db-fs-multi-dep" "$cmd_multi_dep" \
    -n "cli-prepare-batch" "$cmd_cli_prepare"
  echo "bench-selfhost-cache-probe: wrote $OUT_DIR/selfhost_cache_probe.json"
else
  echo "hyperfine not found; using /usr/bin/time" >&2
  for name in "type-db-fs-multi-dep" "cli-prepare-batch"; do
    case "$name" in
      "type-db-fs-multi-dep") cmd="$cmd_multi_dep" ;;
      "cli-prepare-batch") cmd="$cmd_cli_prepare" ;;
    esac
    echo "== $name =="
    /usr/bin/time -p bash -lc "$cmd"
  done
fi
