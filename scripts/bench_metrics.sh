#!/usr/bin/env bash
# Collect the per-commit performance metrics snapshot the continuous perf
# pipeline tracks (the perf-metrics job in .github/workflows/ci.yml, bench/perf/README.md).
#
#   scripts/bench_metrics.sh <stage2.wasm> [out.json]
#
# Metric classes:
#   DETERMINISTIC (byte-stable for a fixed commit -> tight regression flags):
#     - selfcompile heap_ptr_bytes (scripts/selfcompile_kpi.sh, cold cache)
#     - stage2.wasm size + committed bundle/module-source sizes
#     - compiled wasm size of each bench/binary_size sample
#     - bytes_per_op of every tracked `bench {}` block (bump-alloc delta)
#     - exec corpus (bench/exec/): wasmtime FUEL (instruction-count proxy),
#       heap/committed bytes and wasm size per scenario, on BOTH the linear
#       and the wasm-gc backend, plus golden-output and linear-vs-gc parity
#       checks (a mismatch = silent-wrong candidate, flagged loudly)
#   ADVISORY (wall time; machine/load dependent — recorded in the snapshot
#   for bench-data history/offline analysis, deliberately NOT rendered in the
#   per-PR report; see scripts/bench_report.mjs header):
#     - selfcompile wall_ms (median of VIBE_BENCH_KPI_RUNS, default 3)
#     - ns_p50 of every tracked bench block
#
# Micro benches need the viberun runtime; they are skipped (with a note in the
# JSON) unless VIBE_RUNNER points at a viberun binary or
# runtime/viberun/target/release/viberun exists.
#
# RUNNER NORMALIZATION (calibration): advisory wall-time numbers are only
# comparable across CI runs if the underlying runner's raw speed didn't
# change between them -- shared GitHub-hosted runners routinely do (see the
# #1207 perf-report investigation: two unrelated PRs showed every single
# advisory metric move together by a similar magnitude in OPPOSITE
# directions, the signature of runner-to-runner variance, not a real
# regression in either PR). To make that visible instead of guessed at from
# a same-machine re-run, also bench ONE fixed, already-tracked series
# against the COMMITTED SEED (bootstrap/seed/compiler.wasm) instead of the
# PR's freshly-built $STAGE2. The seed only changes on a deliberate bootstrap
# bump (docs/bootstrap.md), so this number is comparable across almost every
# historical run and isolates "how fast is THIS runner right now" from
# anything about the PR's own codegen. bench_report.mjs uses the ratio of
# this run's calibration reading to the baseline's as a per-report
# normalization factor for the advisory section.
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
micro_status="skipped (no viberun runtime)"
RUNNER_BIN="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
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

# --- exec scenarios: fuel / memory / backend parity (deterministic) -----------
# bench/exec/*.vibe are general user-shaped programs (NOT the selfhost
# compiler). Each is compiled by $STAGE2 on BOTH backends and executed once
# under viberun with wasmtime fuel metering (VIBE_FUEL=1). Fuel is charged per
# executed instruction from a static cost table, so for these pure programs
# the reading is byte-stable across machines — a deterministic replacement
# for wall time (it is a function of the wasmtime version, recorded below, so
# the report only compares snapshots taken on the same wasmtime). The linear
# stdout is checked against the committed golden (bench/exec/expected/), and
# the gc stdout against the linear stdout (backend parity) — a mismatch is a
# silent-wrong candidate and gets flagged loudly in the report. gc compile/run
# failures are recorded per scenario (visible feature gap), never fatal.
exec_tsv="$work/exec.tsv"; : > "$exec_tsv"
exec_status="skipped (no viberun runtime)"
wasmtime_version="$(awk '/^name = "wasmtime"$/{f=1} f && /^version = /{gsub(/"/,""); print $3; exit}' runtime/viberun/Cargo.lock 2>/dev/null || true)"
if [ -x "$RUNNER_BIN" ] && [ -d bench/exec ]; then
  exec_status="ok"
  for src in bench/exec/*.vibe; do
    name="$(basename "$src" .vibe)"
    lin_wasm="$work/exec_$name.wasm"
    gc_wasm="$work/exec_$name.gc.wasm"
    lin_status="ok"; lin_fuel=""; lin_heap=""; lin_committed=""; lin_bytes=""
    gc_status="ok"; gc_fuel=""; gc_bytes=""; gc_detail=""
    out_status="ok"

    rm -f "$lin_wasm" "$lin_wasm.diag"
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
      "$src" "$lin_wasm" main >/dev/null 2>&1 || true
    if [ -s "$lin_wasm" ]; then
      lin_bytes="$(wc -c < "$lin_wasm")"
      if VIBE_FUEL=1 VIBE_MEM=1 timeout 120 "$RUNNER_BIN" "$lin_wasm" \
          > "$work/exec_$name.out" 2> "$work/exec_$name.err"; then
        lin_fuel="$(sed -n 's/^vibe::fuel consumed=\([0-9][0-9]*\)$/\1/p' "$work/exec_$name.err" | tail -1)"
        mem_line="$(grep '^vibe::mem ' "$work/exec_$name.err" | tail -1 || true)"
        lin_heap="$(sed -n 's/.*allocated=\([0-9][0-9]*\).*/\1/p' <<<"$mem_line")"
        lin_committed="$(sed -n 's/.*committed=\([0-9][0-9]*\).*/\1/p' <<<"$mem_line")"
        golden="bench/exec/expected/$name.txt"
        if [ ! -f "$golden" ]; then
          out_status="no-golden"
        elif ! cmp -s "$work/exec_$name.out" "$golden"; then
          out_status="golden-mismatch"
        fi
      else
        lin_status="run-failed"
        out_status="skipped"
      fi
    else
      lin_status="compile-failed"
      out_status="skipped"
    fi

    rm -f "$gc_wasm" "$gc_wasm.diag"
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_BACKEND=gc VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
      "$src" "$gc_wasm" main >/dev/null 2>&1 || true
    if [ -s "$gc_wasm" ]; then
      gc_bytes="$(wc -c < "$gc_wasm")"
      if VIBE_FUEL=1 timeout 120 "$RUNNER_BIN" "$gc_wasm" \
          > "$work/exec_$name.gc.out" 2> "$work/exec_$name.gc.err"; then
        gc_fuel="$(sed -n 's/^vibe::fuel consumed=\([0-9][0-9]*\)$/\1/p' "$work/exec_$name.gc.err" | tail -1)"
        if [ "$lin_status" = "ok" ] && [ "$out_status" != "skipped" ] \
            && ! cmp -s "$work/exec_$name.out" "$work/exec_$name.gc.out"; then
          if [ "$out_status" = "ok" ]; then out_status="parity-mismatch"; else out_status="$out_status,parity-mismatch"; fi
        fi
      else
        gc_status="run-failed"
        gc_detail="$(tail -1 "$work/exec_$name.gc.err" | tr '\t' ' ' | cut -c1-160)"
      fi
    else
      gc_status="compile-failed"
      if [ -s "$gc_wasm.diag" ]; then
        gc_detail="$(head -1 "$gc_wasm.diag" | tr '\t' ' ' | cut -c1-160)"
      fi
    fi

    if [ "$lin_status" != "ok" ] || [ "$out_status" != "ok" ]; then
      echo "[bench-metrics] WARN: exec scenario $name: linear=$lin_status output=$out_status" >&2
      exec_status="partial"
    fi
    if [ "$gc_status" != "ok" ]; then
      echo "[bench-metrics] note: exec scenario $name: gc=$gc_status ${gc_detail:+($gc_detail)}" >&2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$lin_status" "$lin_fuel" "$lin_heap" "$lin_committed" "$lin_bytes" \
      "$gc_status" "$gc_fuel" "$gc_bytes" "$out_status" "$gc_detail" >> "$exec_tsv"
  done
  echo "[bench-metrics] exec scenarios: $(wc -l < "$exec_tsv") cases ($exec_status, wasmtime $wasmtime_version)"
else
  echo "[bench-metrics] exec scenarios skipped (runtime: $RUNNER_BIN)"
fi

# --- runner-normalization calibration ------------------------------------------
# One fixed, already-tracked series, compiled by the COMMITTED SEED instead of
# $STAGE2 -- see the file header for why this isolates runner speed from the
# PR's own codegen. Reuses the same runner binary/iters as the real micro
# benches so it experiences the same warmup/measurement characteristics.
#
# MUST be a bench the seed can always compile: the seed only updates on a
# deliberate bootstrap bump (docs/bootstrap.md) while files under
# lib/@vibe/compiler/ (e.g. parser_bench.vibe) keep evolving with the
# compiler and routinely use syntax newer seeds don't understand yet --
# confirmed by hand: the seed fails outright to compile
# lib/@vibe/compiler/parser_bench.vibe ("failed to compile: wasm[...]").
# bench/regression/*.vibe are plain, syntax-stable programs with no such
# risk. alloc_bench's build_100 (~10us/op) is also far less noisy than
# pure_bench's fib30 (~70ns/op, dominated by measurement overhead).
#
# All THREE calibration inputs must be pinned and compared, not just the
# seed: $RUNNER_BIN (viberun) is built from the CURRENT checkout, and
# $CALIB_BENCH is read from the CURRENT checkout too -- a PR that changes
# runtime/viberun or bench/regression/alloc_bench.vibe would otherwise have
# that real change misread as pure host-speed drift and divided out of
# every advisory delta (found in review, #1209).
CALIB_BENCH="${VIBE_CALIBRATION_BENCH:-bench/regression/alloc_bench.vibe}"
CALIB_LABEL="${VIBE_CALIBRATION_LABEL:-build_100}"
CALIB_KEY="$(basename "$CALIB_BENCH")::$CALIB_LABEL"
SEED_WASM="${VIBE_CALIBRATION_SEED:-bootstrap/seed/compiler.wasm}"
calib_ns=""
calib_seed_sha=""
calib_runner_sha=""
calib_bench_sha=""
if [ -x "$RUNNER_BIN" ] && [ -f "$CALIB_BENCH" ] && [ -s "$SEED_WASM" ]; then
  calib_seed_sha="$(sha256sum "$SEED_WASM" | cut -d' ' -f1)"
  calib_runner_sha="$(sha256sum "$RUNNER_BIN" | cut -d' ' -f1)"
  calib_bench_sha="$(sha256sum "$CALIB_BENCH" | cut -d' ' -f1)"
  calib_line="$(VIBE_RUNNER="$RUNNER_BIN" VIBE_CLI_WASM="$(cd "$(dirname "$SEED_WASM")" && pwd)/$(basename "$SEED_WASM")" \
    timeout 300 ./runtime/vibe bench "$CALIB_BENCH" --iters "$BENCH_ITERS" 2>/dev/null \
    | grep "^vibe::bench label=$CALIB_KEY " || true)"
  calib_ns="$(sed -n 's/^vibe::bench label=[^ ]* .* ns_p50=\([0-9]*\).*/\1/p' <<<"$calib_line")"
  if [ -n "$calib_ns" ]; then
    echo "[bench-metrics] calibration ($CALIB_KEY via seed) ns_p50=$calib_ns seed_sha256=${calib_seed_sha:0:12} runner_sha256=${calib_runner_sha:0:12} bench_sha256=${calib_bench_sha:0:12}"
  else
    echo "[bench-metrics] WARN: calibration run failed, normalization unavailable for this snapshot" >&2
  fi
else
  echo "[bench-metrics] calibration skipped (runner/bench/seed unavailable)"
fi

# --- assemble JSON ------------------------------------------------------------
BM_HEAP="$heap" BM_WALL_MEDIAN="$wall_median" BM_WALL_RUNS="${walls[*]}" \
BM_STAGE2="$stage2_bytes" BM_ADAPTER="$adapter_bundle_bytes" \
BM_SOURCES="$sources_bundle_bytes" BM_MODSRC="$module_source_bytes" \
BM_MICRO_STATUS="$micro_status" \
BM_EXEC_STATUS="$exec_status" BM_WASMTIME="$wasmtime_version" \
BM_CALIB_NS="$calib_ns" BM_CALIB_SEED_SHA="$calib_seed_sha" \
BM_CALIB_RUNNER_SHA="$calib_runner_sha" BM_CALIB_BENCH_SHA="$calib_bench_sha" \
BM_CALIB_LABEL="$CALIB_KEY" \
node - "$OUT_JSON" "$samples_tsv" "$bench_tsv" "$exec_tsv" <<'NODE'
const fs = require("fs");
const [out, samplesTsv, benchTsv, execTsv] = process.argv.slice(2);
const tsv = (p) => fs.existsSync(p)
  ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map(l => l.split("\t"))
  : [];
const samples = {}; for (const [k, v] of tsv(samplesTsv)) samples[k] = +v;
const benches = {}; for (const [k, ns, b] of tsv(benchTsv)) benches[k] = { ns_p50: +ns, bytes_per_op: +b };
// Exec scenarios (deterministic fuel/memory/parity — see the collection loop
// above). Numeric fields are null when the lane didn't produce them (compile/
// run failure) — consumers must treat null as "no data", not zero.
const num = (s) => (s === "" || s == null ? null : +s);
const execScenarios = {};
for (const [name, linStatus, linFuel, linHeap, linCommitted, linBytes,
             gcStatus, gcFuel, gcBytes, outStatus, gcDetail] of tsv(execTsv)) {
  execScenarios[name] = {
    linear: { status: linStatus, fuel: num(linFuel), heap_bytes: num(linHeap),
              committed_bytes: num(linCommitted), wasm_bytes: num(linBytes) },
    gc: { status: gcStatus, fuel: num(gcFuel), wasm_bytes: num(gcBytes),
          detail: gcDetail || null },
    output: outStatus,
  };
}
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
  // Runner-normalization calibration (see file header): null fields mean the
  // calibration run didn't produce data (older snapshot, or runner/seed
  // unavailable) -- consumers must treat that as "normalization unavailable",
  // not as a zero. All three hashes (seed/runner/bench source) must match
  // between two snapshots before their calibration readings are comparable
  // -- a PR that changes runtime/viberun or the calibration bench itself
  // must not have that show up as pure runner-speed drift (#1209 review).
  calibration: {
    label: process.env.BM_CALIB_LABEL || null,
    ns_p50: process.env.BM_CALIB_NS ? +process.env.BM_CALIB_NS : null,
    seed_sha256: process.env.BM_CALIB_SEED_SHA || null,
    runner_sha256: process.env.BM_CALIB_RUNNER_SHA || null,
    bench_sha256: process.env.BM_CALIB_BENCH_SHA || null,
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
  // Deterministic execution metrics for the general-program corpus
  // (bench/exec/README.md). `wasmtime` records the metering engine version:
  // fuel readings are only comparable between snapshots with the same value
  // (the per-instruction cost table lives in wasmtime).
  exec: {
    status: process.env.BM_EXEC_STATUS,
    wasmtime: process.env.BM_WASMTIME || null,
    scenarios: execScenarios,
  },
};
fs.writeFileSync(out, JSON.stringify(doc, null, 2) + "\n");
console.log("[bench-metrics] wrote " + out);
NODE
