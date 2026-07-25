#!/usr/bin/env bash
# Collect the per-commit performance metrics snapshot the continuous perf
# pipeline tracks (.github/workflows/perf.yml, bench/perf/README.md).
#
#   scripts/bench_metrics.sh <stage2.wasm> [out.json]
#
# Metric classes:
#   DETERMINISTIC (byte-stable for a fixed commit -> tight regression flags):
#     - selfcompile heap_ptr_bytes (scripts/selfcompile_kpi.sh, cold cache)
#     - stage2.wasm size + committed bundle/module-source sizes
#     - compiled wasm size of each bench/binary_size sample
#     - bytes_per_op of every tracked `bench {}` block (bump-alloc delta)
#   ADVISORY (wall time; machine/load dependent -> loose flags, never gate):
#     - selfcompile wall_ms (median of VIBE_BENCH_KPI_RUNS, default 3)
#     - ns_p50 of every tracked bench block
#
# Micro benches need the vibewt runtime; they are skipped (with a note in the
# JSON) unless VIBE_RUNNER points at a vibewt binary or
# runtime/vibewt/target/release/vibewt exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

STAGE2="${1:-}"
OUT_JSON="${2:-_build/bench_metrics.json}"
[ -n "$STAGE2" ] && [ -s "$STAGE2" ] || { echo "usage: scripts/bench_metrics.sh <stage2.wasm> [out.json]" >&2; exit 2; }
mkdir -p "$(dirname "$OUT_JSON")"

KPI_RUNS="${VIBE_BENCH_KPI_RUNS:-3}"
BENCH_ITERS="${VIBE_BENCH_ITERS:-100}"
TRACKED="${VIBE_TRACKED_BENCHES:-bench/perf/tracked_benches.txt}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- selfcompile KPI: heap (deterministic) + wall (median of N) ---------------
heap=""
walls=()
for i in $(seq 1 "$KPI_RUNS"); do
  line="$(bash scripts/selfcompile_kpi.sh "$STAGE2" | grep '\[selfcompile-kpi\]' | tail -1)"
  h="$(sed -n 's/.*heap_ptr_bytes=\([0-9][0-9]*\).*/\1/p' <<<"$line")"
  w="$(sed -n 's/.*wall_ms=\([0-9][0-9]*\).*/\1/p' <<<"$line")"
  [ -n "$h" ] && [ -n "$w" ] || { echo "[bench-metrics] KPI run $i produced no metrics" >&2; exit 1; }
  if [ -n "$heap" ] && [ "$heap" != "$h" ]; then
    echo "[bench-metrics] WARN: heap_ptr_bytes not stable across runs ($heap vs $h)" >&2
  fi
  heap="$h"
  walls+=("$w")
done
wall_median="$(printf '%s\n' "${walls[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')"
echo "[bench-metrics] selfcompile heap_ptr_bytes=$heap wall_ms_median=$wall_median (runs: ${walls[*]})"

# --- sizes (deterministic) ----------------------------------------------------
stage2_bytes="$(wc -c < "$STAGE2")"
adapter_bundle_bytes="$(wc -c < lib/@vibe/compiler/cli_adapter_bundle.vibe)"
sources_bundle_bytes="$(wc -c < lib/@vibe/compiler/compiler_sources_bundle.vibe)"
module_source_bytes="$(wc -c < lib/@vibe/compiler/_cli_adapter_module_source.vibe)"

# compiled wasm size of each binary_size sample (release-shape compile)
samples_tsv="$work/samples.tsv"; : > "$samples_tsv"
for src in bench/binary_size/*.vibe; do
  name="$(basename "$src" .vibe)"
  out="$work/$name.wasm"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$src" "$out" main >/dev/null 2>&1 || true
  if [ -s "$out" ]; then
    printf '%s\t%s\n' "$name" "$(wc -c < "$out")" >> "$samples_tsv"
  else
    echo "[bench-metrics] WARN: binary_size sample failed to compile: $src" >&2
  fi
done

# --- micro benches (bytes_per_op deterministic, ns_p50 advisory) --------------
bench_tsv="$work/bench.tsv"; : > "$bench_tsv"
micro_status="skipped (no vibewt runtime)"
RUNNER_BIN="${VIBE_RUNNER:-$ROOT_DIR/runtime/vibewt/target/release/vibewt}"
if [ -x "$RUNNER_BIN" ] && [ -f "$TRACKED" ]; then
  micro_status="ok"
  while IFS= read -r bf; do
    case "$bf" in ''|\#*) continue ;; esac
    if [ ! -f "$bf" ]; then
      echo "[bench-metrics] WARN: tracked bench missing: $bf" >&2
      micro_status="partial"
      continue
    fi
    if ! VIBE_RUNNER="$RUNNER_BIN" VIBE_CLI_WASM="$(cd "$(dirname "$STAGE2")" && pwd)/$(basename "$STAGE2")" \
      timeout 300 ./runtime/vibe bench "$bf" --iters "$BENCH_ITERS" 2>/dev/null \
      | grep '^vibe::bench ' \
      | sed -n 's/^vibe::bench label=\([^ ]*\) .* ns_p50=\([0-9]*\) .* bytes_per_op=\([0-9]*\).*/\1\t\2\t\3/p' \
      >> "$bench_tsv"; then
      echo "[bench-metrics] WARN: bench run failed: $bf" >&2
      micro_status="partial"
    fi
  done < "$TRACKED"
  echo "[bench-metrics] micro benches: $(wc -l < "$bench_tsv") series ($micro_status)"
else
  echo "[bench-metrics] micro benches skipped (runtime: $RUNNER_BIN)"
fi

# --- assemble JSON ------------------------------------------------------------
BM_HEAP="$heap" BM_WALL_MEDIAN="$wall_median" BM_WALL_RUNS="${walls[*]}" \
BM_STAGE2="$stage2_bytes" BM_ADAPTER="$adapter_bundle_bytes" \
BM_SOURCES="$sources_bundle_bytes" BM_MODSRC="$module_source_bytes" \
BM_MICRO_STATUS="$micro_status" \
node - "$OUT_JSON" "$samples_tsv" "$bench_tsv" <<'NODE'
const fs = require("fs");
const [out, samplesTsv, benchTsv] = process.argv.slice(2);
const tsv = (p) => fs.existsSync(p)
  ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map(l => l.split("\t"))
  : [];
const samples = {}; for (const [k, v] of tsv(samplesTsv)) samples[k] = +v;
const benches = {}; for (const [k, ns, b] of tsv(benchTsv)) benches[k] = { ns_p50: +ns, bytes_per_op: +b };
const sh = (c) => require("child_process").execSync(c, { encoding: "utf8" }).trim();
let commit = process.env.GITHUB_SHA || "";
try { if (!commit) commit = sh("git rev-parse HEAD"); } catch {}
const doc = {
  schema: 1,
  commit,
  date: new Date().toISOString(),
  selfcompile: {
    heap_ptr_bytes: +process.env.BM_HEAP,
    wall_ms_median: +process.env.BM_WALL_MEDIAN,
    wall_ms_runs: process.env.BM_WALL_RUNS.split(/\s+/).filter(Boolean).map(Number),
  },
  sizes: {
    stage2_wasm: +process.env.BM_STAGE2,
    cli_adapter_bundle: +process.env.BM_ADAPTER,
    compiler_sources_bundle: +process.env.BM_SOURCES,
    module_source: +process.env.BM_MODSRC,
    samples,
  },
  benches,
  micro_status: process.env.BM_MICRO_STATUS,
};
fs.writeFileSync(out, JSON.stringify(doc, null, 2) + "\n");
console.log("[bench-metrics] wrote " + out);
NODE
