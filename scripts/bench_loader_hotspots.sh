#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="${CLI_BIN:-$ROOT_DIR/_build/native/release/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/_build/bench/selfhost_loader_hotspots}"
RUNS="${VIBE_LOADER_HOTSPOT_RUNS:-3}"
WARMUP="${VIBE_LOADER_HOTSPOT_WARMUP:-0}"
MICRO_RUNS="${VIBE_LOADER_HOTSPOT_MICRO_RUNS:-$RUNS}"
SKIP_MICRO="${VIBE_LOADER_HOTSPOT_SKIP_MICRO:-0}"
BACKEND="${VIBE_LOADER_HOTSPOT_BACKEND:-compiled}"
COLLECT_BENCH_FILE="${VIBE_LOADER_COLLECT_BENCH_FILE:-$ROOT_DIR/lib/@vibe/compiler/loader_collect_bench.vibe}"
GROUP_MATERIALIZE_BENCH_FILE="${VIBE_LOADER_GROUP_MATERIALIZE_BENCH_FILE:-$ROOT_DIR/lib/@vibe/compiler/loader_materialize_bench.vibe}"
LIST_MATERIALIZE_BENCH_FILE="${VIBE_LOADER_LIST_MATERIALIZE_BENCH_FILE:-$ROOT_DIR/lib/@vibe/compiler/loader_list_materialize_bench.vibe}"
COLLECT_JSON_OUT="$OUT_DIR/selfhost_loader_collect.json"
GROUP_JSON_OUT="$OUT_DIR/selfhost_loader_groups_materialize.json"
LIST_JSON_OUT="$OUT_DIR/selfhost_loader_list_materialize.json"

mkdir -p "$OUT_DIR"

if [[ ! -x "$CLI_BIN" ]]; then
  echo "bench-loader-hotspots: missing CLI_BIN: $CLI_BIN" >&2
  exit 1
fi

"$CLI_BIN" bench \
  --backend "$BACKEND" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --json \
  --json-out "$COLLECT_JSON_OUT" \
  "$COLLECT_BENCH_FILE"

echo "bench-loader-hotspots: wrote $COLLECT_JSON_OUT"
if [[ "$SKIP_MICRO" != "1" ]]; then
  "$CLI_BIN" bench \
    --backend "$BACKEND" \
    --runs "$MICRO_RUNS" \
    --warmup "$WARMUP" \
    --json \
    --case selfhost/loader_manifest_groups_linear \
    --case selfhost/loader_manifest_groups_indexed \
    --json-out "$GROUP_JSON_OUT" \
    "$GROUP_MATERIALIZE_BENCH_FILE"

  "$CLI_BIN" bench \
    --backend "$BACKEND" \
    --runs "$MICRO_RUNS" \
    --warmup "$WARMUP" \
    --json \
    --case selfhost/loader_manifest_list_filter_linear \
    --case selfhost/loader_manifest_list_filter_path_indexed \
    --case selfhost/loader_manifest_list_filter_indexed \
    --json-out "$LIST_JSON_OUT" \
    "$LIST_MATERIALIZE_BENCH_FILE"

  echo "bench-loader-hotspots: wrote $GROUP_JSON_OUT"
  echo "bench-loader-hotspots: wrote $LIST_JSON_OUT"
else
  echo "bench-loader-hotspots: skipping micro benches (set VIBE_LOADER_HOTSPOT_SKIP_MICRO=0 to enable)"
fi
