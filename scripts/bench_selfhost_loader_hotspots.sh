#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="${CLI_BIN:-$ROOT_DIR/_build/native/release/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/_build/bench/selfhost_loader_hotspots}"
RUNS="${VIBE_SELFHOST_LOADER_HOTSPOT_RUNS:-3}"
WARMUP="${VIBE_SELFHOST_LOADER_HOTSPOT_WARMUP:-0}"
BACKEND="${VIBE_SELFHOST_LOADER_HOTSPOT_BACKEND:-interpreter}"
TIMEOUT_SEC="${VIBE_SELFHOST_LOADER_HOTSPOT_TIMEOUT_SEC:-60}"

mkdir -p "$OUT_DIR"

if [[ ! -x "$CLI_BIN" ]]; then
  echo "bench-selfhost-loader-hotspots: missing CLI_BIN: $CLI_BIN" >&2
  exit 1
fi

cmd_loader_list="timeout $TIMEOUT_SEC env VIBE_RUN_BACKEND=$BACKEND \"$CLI_BIN\" run \"$ROOT_DIR/vibe/compiler/bench_loader_manifest_list_run.vibe\" >/dev/null"
cmd_loader_groups="timeout $TIMEOUT_SEC env VIBE_RUN_BACKEND=$BACKEND \"$CLI_BIN\" run \"$ROOT_DIR/vibe/compiler/bench_loader_manifest_groups_run.vibe\" >/dev/null"
cmd_file_compile_same="timeout $TIMEOUT_SEC env VIBE_RUN_BACKEND=$BACKEND \"$CLI_BIN\" run \"$ROOT_DIR/vibe/compiler/bench_file_compile_mode_same_content_run.vibe\" >/dev/null"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$OUT_DIR/selfhost_loader_hotspots.json" \
    -n "loader-manifest-list" "$cmd_loader_list" \
    -n "loader-manifest-groups" "$cmd_loader_groups" \
    -n "file-compile-mode-same-content" "$cmd_file_compile_same"
  echo "bench-selfhost-loader-hotspots: wrote $OUT_DIR/selfhost_loader_hotspots.json"
else
  echo "hyperfine not found; using /usr/bin/time" >&2
  for name in "loader-manifest-list" "loader-manifest-groups" "file-compile-mode-same-content"; do
    case "$name" in
      "loader-manifest-list") cmd="$cmd_loader_list" ;;
      "loader-manifest-groups") cmd="$cmd_loader_groups" ;;
      "file-compile-mode-same-content") cmd="$cmd_file_compile_same" ;;
    esac
    echo "== $name =="
    /usr/bin/time -p bash -lc "$cmd"
  done
fi
