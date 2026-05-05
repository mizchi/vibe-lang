#!/usr/bin/env bash
# Run vibe bench on the selfhost lexer/parser/checker micro-bench files.
# Each phase is a separate vibe bench invocation so JSON output is per-phase.
set -euo pipefail

trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI_BIN="${CLI_BIN:-$VIBE_CLI_BIN}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/_build/bench/selfhost_compile_hotspots}"
RUNS="${VIBE_SELFHOST_COMPILE_HOTSPOT_RUNS:-3}"
WARMUP="${VIBE_SELFHOST_COMPILE_HOTSPOT_WARMUP:-0}"
BACKEND="${VIBE_SELFHOST_COMPILE_HOTSPOT_BACKEND:-compiled}"
PHASES_RAW="${VIBE_SELFHOST_COMPILE_HOTSPOT_PHASES:-lexer,parser,checker}"

LEXER_BENCH_FILE="${VIBE_SELFHOST_LEXER_BENCH_FILE:-$ROOT_DIR/vibe/compiler/selfhost_lexer_bench.vibe}"
PARSER_BENCH_FILE="${VIBE_SELFHOST_PARSER_BENCH_FILE:-$ROOT_DIR/vibe/compiler/selfhost_parser_bench.vibe}"
CHECKER_BENCH_FILE="${VIBE_SELFHOST_CHECKER_BENCH_FILE:-$ROOT_DIR/vibe/compiler/selfhost_checker_bench.vibe}"

mkdir -p "$OUT_DIR"

if [[ ! -x "$CLI_BIN" ]]; then
  echo "bench-selfhost-compile-hotspots: missing CLI_BIN: $CLI_BIN" >&2
  exit 1
fi

IFS=',' read -ra PHASES <<< "$PHASES_RAW"

run_phase() {
  local name="$1"
  local file="$2"
  local out_json="$OUT_DIR/selfhost_${name}_hotspots.json"
  if [[ ! -f "$file" ]]; then
    echo "bench-selfhost-compile-hotspots: missing bench file: $file" >&2
    exit 1
  fi
  echo "[selfhost-compile-hotspots] phase=${name} file=${file#$ROOT_DIR/}"
  "$CLI_BIN" bench \
    --backend "$BACKEND" \
    --runs "$RUNS" \
    --warmup "$WARMUP" \
    --json \
    --json-out "$out_json" \
    "$file"
  echo "bench-selfhost-compile-hotspots: wrote $out_json"
}

for ph in "${PHASES[@]}"; do
  case "$ph" in
    lexer)   run_phase lexer   "$LEXER_BENCH_FILE" ;;
    parser)  run_phase parser  "$PARSER_BENCH_FILE" ;;
    checker) run_phase checker "$CHECKER_BENCH_FILE" ;;
    *) echo "bench-selfhost-compile-hotspots: unknown phase '$ph'" >&2; exit 1 ;;
  esac
done
