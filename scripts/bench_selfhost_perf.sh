#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_CLI_RELEASE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"

SELFHOST_WASM_PROFILE="${VIBE_SELFHOST_PERF_WASM_PROFILE:-debug}"
DEFAULT_STAGE1_COMPILER_WASM="$PROJECT_ROOT/_build/wasm/$SELFHOST_WASM_PROFILE/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
DEFAULT_STAGE1_CHECKER_WASM="$PROJECT_ROOT/_build/wasm/$SELFHOST_WASM_PROFILE/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
VIBE_BIN="${VIBE_BIN:-$VIBE_CLI_BIN}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$DEFAULT_STAGE1_COMPILER_WASM}"
STAGE1_CHECKER_WASM="${STAGE1_CHECKER_WASM:-$DEFAULT_STAGE1_CHECKER_WASM}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_perf}"
CASES_FILE="${VIBE_SELFHOST_PERF_CASES_FILE:-$PROJECT_ROOT/bench/selfhost_perf/cases.txt}"
RUNS="${VIBE_SELFHOST_PERF_RUNS:-3}"
COMPILE_MODE="${VIBE_SELFHOST_PERF_COMPILE_MODE:-e2e}"
MAX_CASE_COMPILE_RATIO="${VIBE_SELFHOST_PERF_MAX_CASE_COMPILE_RATIO:-}"
MAX_CASE_CHECK_RATIO="${VIBE_SELFHOST_PERF_MAX_CASE_CHECK_RATIO:-}"
MAX_TOTAL_COMPILE_RATIO="${VIBE_SELFHOST_PERF_MAX_TOTAL_COMPILE_RATIO:-}"
MAX_TOTAL_CHECK_RATIO="${VIBE_SELFHOST_PERF_MAX_TOTAL_CHECK_RATIO:-}"
REBUILD_MODE="${VIBE_SELFHOST_PERF_REBUILD:-auto}"
WASM_OPT_MODE="${VIBE_SELFHOST_PERF_WASM_OPT:-auto}"
PROFILE_CALLSTACK="${VIBE_SELFHOST_PERF_PROFILE_CALLSTACK:-}"
# Runtime that hosts the stage1 wasm.
#   moonrun              — legacy v8 interpreter (no rust toolchain needed)
#   moonrun-wt|wasmtime  — moonrun_wt custom host, wasmtime crate, no precompile
#   moonrun-wt-aot|wasmtime-aot
#                        — moonrun_wt custom host with .cwasm precompile (default)
# wasmtime-aot was the default starting on this PoC branch (#402 Phase 2);
# selfhost compile ratio dropped from 2.71 → 0.80 on the KPI cases.
# Set VIBE_SELFHOST_PERF_RUNTIME=moonrun to opt back into the v8 path
# (e.g. environments without rust + cargo).
SELFHOST_RUNTIME="${VIBE_SELFHOST_PERF_RUNTIME:-wasmtime-aot}"
MOONRUN_WT_BIN="${MOONRUN_WT_BIN:-}"
# Opt-in: use moonrun_wt --daemon for selfhost check requests.
#
# When set, ALL (case × run) check requests are funneled through a
# *single* warm wasm instance — so `ensure_builtin_modules` is paid
# exactly once for the whole bench instead of once per case. This
# mirrors how a production LSP / vibe-check-as-service would batch
# work, and matches the host side's session-http amortization.
#
# Only applies when SELFHOST_RUNTIME uses moonrun_wt
# (wasmtime|wasmtime-aot|moonrun-wt|moonrun-wt-aot).
# Median across RUNS still drops the first (cold) outlier when
# RUNS ≥ 3; with cross-case daemon mode only request #1 of case #1
# is cold, the rest are pure-warm-ratio.
CHECK_DAEMON_MODE="${VIBE_SELFHOST_PERF_CHECK_DAEMON:-0}"

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)'
}

median_file_ms() {
  local file="$1"
  local count odd_mid even_mid_a even_mid_b
  count="$(wc -l < "$file" | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    echo "0"
    return
  fi
  if [ $((count % 2)) -eq 1 ]; then
    odd_mid=$((count / 2 + 1))
    sort -n "$file" | sed -n "${odd_mid}p"
  else
    even_mid_a=$((count / 2))
    even_mid_b=$((even_mid_a + 1))
    local a b
    a="$(sort -n "$file" | sed -n "${even_mid_a}p")"
    b="$(sort -n "$file" | sed -n "${even_mid_b}p")"
    echo $(((a + b) / 2))
  fi
}

calc_ratio() {
  local lhs="$1"
  local rhs="$2"
  if [ "$rhs" -eq 0 ]; then
    echo "0.000"
    return
  fi
  awk -v lhs="$lhs" -v rhs="$rhs" 'BEGIN { printf "%.3f", lhs / rhs }'
}

ratio_exceeds() {
  local ratio="$1"
  local limit="$2"
  awk -v r="$ratio" -v l="$limit" 'BEGIN { if (r > l) exit 0; exit 1 }'
}

runtime_uses_moonrun_wt() {
  case "$SELFHOST_RUNTIME" in
    wasmtime|wasmtime-aot|moonrun-wt|moonrun-wt-aot) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_uses_cwasm() {
  case "$SELFHOST_RUNTIME" in
    wasmtime-aot|moonrun-wt-aot) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_default_wasm_opt_level() {
  case "$SELFHOST_RUNTIME" in
    moonrun) printf '%s\n' "-Oz" ;;
    wasmtime|wasmtime-aot|moonrun-wt|moonrun-wt-aot) printf '%s\n' "-O3" ;;
    *) printf '%s\n' "-Oz" ;;
  esac
}

runtime_label() {
  case "$SELFHOST_RUNTIME" in
    moonrun) printf '%s\n' "moonrun/v8" ;;
    wasmtime|moonrun-wt) printf '%s\n' "moonrun_wt/wasmtime" ;;
    wasmtime-aot|moonrun-wt-aot) printf '%s\n' "moonrun_wt/wasmtime-aot" ;;
    *) printf '%s\n' "$SELFHOST_RUNTIME" ;;
  esac
}

run_timed() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2
  local start_ms end_ms elapsed_ms status
  start_ms="$(now_ms)"
  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e
  end_ms="$(now_ms)"
  elapsed_ms="$((end_ms - start_ms))"
  echo "$status $elapsed_ms"
}

collect_cases() {
  if [ "$#" -gt 0 ]; then
    for p in "$@"; do
      if [ -f "$PROJECT_ROOT/$p" ]; then
        echo "$PROJECT_ROOT/$p"
      elif [ -f "$p" ]; then
        echo "$p"
      else
        echo "bench-selfhost-perf: case not found: $p" >&2
        exit 1
      fi
    done
    return
  fi

  if [ ! -f "$CASES_FILE" ]; then
    echo "bench-selfhost-perf: cases file not found: $CASES_FILE" >&2
    exit 1
  fi

  while IFS= read -r row; do
    row="${row#"${row%%[![:space:]]*}"}"
    [ -z "$row" ] && continue
    [[ "$row" == \#* ]] && continue
    if [ -f "$PROJECT_ROOT/$row" ]; then
      echo "$PROJECT_ROOT/$row"
    else
      echo "bench-selfhost-perf: case not found: $row" >&2
      exit 1
    fi
  done < "$CASES_FILE"
}

source_changed_since() {
  local artifact="$1"
  find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$PROJECT_ROOT" -maxdepth 1 -type f \( -name 'moon.mod' -o -name 'moon.mod.json' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q .
}

ensure_binaries() {
  if [ "$SELFHOST_WASM_PROFILE" != "release" ] && [ "$SELFHOST_WASM_PROFILE" != "debug" ]; then
    echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_WASM_PROFILE must be release or debug" >&2
    exit 1
  fi
  if [ "$REBUILD_MODE" != "auto" ] && [ "$REBUILD_MODE" != "always" ] && [ "$REBUILD_MODE" != "never" ]; then
    echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_REBUILD must be auto|always|never" >&2
    exit 1
  fi
  case "$WASM_OPT_MODE" in 1|yes|on|true|auto|0|no|off|false) ;;
    *) echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_WASM_OPT must be auto|on|off" >&2; exit 1 ;;
  esac
  local src_changed_since_host=0
  local src_changed_since_compiler=0
  local src_changed_since_checker=0
  if [ "$REBUILD_MODE" = "always" ]; then
    src_changed_since_host=1
    src_changed_since_compiler=1
    src_changed_since_checker=1
  elif [ "$REBUILD_MODE" = "auto" ]; then
    if [ ! -x "$VIBE_BIN" ] || source_changed_since "$VIBE_BIN"; then
      src_changed_since_host=1
    fi
    if [ ! -f "$STAGE1_COMPILER_WASM" ] || source_changed_since "$STAGE1_COMPILER_WASM"; then
      src_changed_since_compiler=1
    fi
    if [ ! -f "$STAGE1_CHECKER_WASM" ] || source_changed_since "$STAGE1_CHECKER_WASM"; then
      src_changed_since_checker=1
    fi
  fi

  if [ ! -x "$VIBE_BIN" ] || [ "$src_changed_since_host" -eq 1 ]; then
    echo "[selfhost-perf] building host CLI..."
    VIBE_CLI_RELEASE=1 VIBE_CLI_FORCE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
    VIBE_BIN="$VIBE_CLI_BIN"
  fi
  if [ ! -f "$STAGE1_COMPILER_WASM" ] || [ "$src_changed_since_compiler" -eq 1 ]; then
    echo "[selfhost-perf] building selfhost compiler wasm ($SELFHOST_WASM_PROFILE)..."
    if [ "$SELFHOST_WASM_PROFILE" = "release" ]; then
      moon build --target wasm --release src/cmd/vibe_compile_wasi
    else
      moon build --target wasm src/cmd/vibe_compile_wasi
    fi
  fi
  if [ ! -f "$STAGE1_CHECKER_WASM" ] || [ "$src_changed_since_checker" -eq 1 ]; then
    echo "[selfhost-perf] building selfhost checker wasm ($SELFHOST_WASM_PROFILE)..."
    if [ "$SELFHOST_WASM_PROFILE" = "release" ]; then
      moon build --target wasm --release src/cmd/vibe_check_wasi
    else
      moon build --target wasm src/cmd/vibe_check_wasi
    fi
  fi
  # Optional wasm-opt -O3 step. moonrun executes raw moon-built wasm
  # without ahead-of-time optimization; piping through binaryen
  # `wasm-opt -O3` recovers a substantial chunk of the host/selfhost
  # ratio (compile 5.99x -> 3.87x, check 2.66x -> 1.77x on
  # examples/basics.vibe; see bench/selfhost_perf/README.md).
  local want_opt=0
  local moon_wasm_opt="${MOON_HOME:-$HOME/.moon}/bin/moon-wasm-opt"
  case "$WASM_OPT_MODE" in
    1|yes|on|true) want_opt=1 ;;
    auto)
      if [ -x "$moon_wasm_opt" ]; then
        want_opt=1
      elif command -v wasm-opt >/dev/null 2>&1; then
        local v
        v="$(wasm-opt --version 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }')"
        if [ -n "$v" ] && [ "$v" -ge 118 ]; then
          want_opt=1
        fi
      fi
      ;;
  esac
  if [ "$want_opt" -eq 1 ]; then
    # Pick the wasm-opt level that's best for the chosen runtime.
    # Empirical (release+wasm-opt, examples/basics + base64 + effects,
    # mean compile ratio across cases):
    #   runtime         -Oz    -O3    -O4
    #   moonrun         2.48   3.11   3.15   (v8 interp: instruction count wins)
    #   wasmtime-aot    1.02   0.85   0.85   (Cranelift JIT: loop unrolling wins)
    # -O3 cuts ~17% off the wasmtime-aot ratio vs -Oz on the same wasm,
    # so use runtime-aware defaults when caller leaves the level on
    # `auto`. Explicit VIBE_SELFHOST_PERF_WASM_OPT_LEVEL overrides this.
    local opt_level="${VIBE_SELFHOST_PERF_WASM_OPT_LEVEL:-auto}"
    if [ "$opt_level" = "auto" ]; then
      opt_level="$(runtime_default_wasm_opt_level)"
    fi
    # Rebuild the wasm-opt artifact if the recorded level doesn't
    # match the runtime-appropriate level. Otherwise we'd be running
    # moonrun against -O3 wasm (or vice-versa), distorting the bench.
    local opt_marker="$PROJECT_ROOT/_build/wasm/opt/.opt_level"
    local need_rebuild_opt=0
    if [ ! -f "$opt_marker" ] || [ "$(cat "$opt_marker" 2>/dev/null)" != "$opt_level" ]; then
      need_rebuild_opt=1
    fi
    local rebuild_mode_for_opt="$REBUILD_MODE"
    if [ "$need_rebuild_opt" -eq 1 ] && [ "$rebuild_mode_for_opt" != "always" ]; then
      rebuild_mode_for_opt="always"
    fi
    if ! WASM_OPT_LEVEL="$opt_level" VIBE_SELFHOST_OPT_WASM_PROFILE="$SELFHOST_WASM_PROFILE" VIBE_SELFHOST_OPT_WASM_REBUILD="$rebuild_mode_for_opt" bash "$PROJECT_ROOT/scripts/build_selfhost_wasi_opt.sh" >&2; then
      echo "bench-selfhost-perf: wasm-opt step failed; falling back to raw wasm" >&2
    else
      local opt_compiler="$PROJECT_ROOT/_build/wasm/opt/vibe_compile_wasi.wasm"
      local opt_checker="$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.wasm"
      if [ -f "$opt_compiler" ]; then STAGE1_COMPILER_WASM="$opt_compiler"; fi
      if [ -f "$opt_checker" ]; then STAGE1_CHECKER_WASM="$opt_checker"; fi
      echo "$opt_level" > "$opt_marker"
      echo "[selfhost-perf] using wasm-opt'd artifacts under _build/wasm/opt/ (level=$opt_level for runtime=$(runtime_label))"
    fi
  fi
  case "$SELFHOST_RUNTIME" in
    moonrun)
      if ! command -v moonrun >/dev/null 2>&1; then
        echo "bench-selfhost-perf: moonrun not found" >&2
        exit 1
      fi
      ;;
    wasmtime|wasmtime-aot|moonrun-wt|moonrun-wt-aot)
      ensure_moonrun_wt
      if runtime_uses_cwasm; then
        STAGE1_COMPILER_WASM="$(ensure_cwasm "$STAGE1_COMPILER_WASM")"
        STAGE1_CHECKER_WASM="$(ensure_cwasm "$STAGE1_CHECKER_WASM")"
      fi
      ;;
    *)
      echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_RUNTIME must be moonrun|moonrun-wt|moonrun-wt-aot|wasmtime|wasmtime-aot" >&2
      exit 1
      ;;
  esac
}

# Resolve / build moonrun_wt. This is a custom Rust host that embeds wasmtime
# as a crate and re-implements moonrun's import surface; it is not the wasmtime
# CLI used by `scripts/wasmtime_bin.sh`.
ensure_moonrun_wt() {
  if [ -n "${MOONRUN_WT_BIN:-}" ] && [ -x "$MOONRUN_WT_BIN" ]; then
    return 0
  fi
  local default_bin="$PROJECT_ROOT/tools/moonrun_wasmtime/target/release/moonrun_wt"
  if [ ! -x "$default_bin" ] || [ "$REBUILD_MODE" = "always" ]; then
    echo "[selfhost-perf] building moonrun_wt (wasmtime host)..."
    (cd "$PROJECT_ROOT/tools/moonrun_wasmtime" && cargo build --release >&2)
  fi
  MOONRUN_WT_BIN="$default_bin"
  if [ ! -x "$MOONRUN_WT_BIN" ]; then
    echo "bench-selfhost-perf: moonrun_wt build did not produce $MOONRUN_WT_BIN" >&2
    exit 1
  fi
}

# Pre-compile `.wasm` → `.cwasm` for the wasmtime-aot runtime path.
# Skips work when the cwasm is newer than the input. Echoes the cwasm path.
ensure_cwasm() {
  local wasm_path="$1"
  local cwasm_path="${wasm_path%.wasm}.cwasm"
  if [ ! -f "$cwasm_path" ] || [ "$wasm_path" -nt "$cwasm_path" ]; then
    echo "[selfhost-perf] AOT-compiling $(basename "$wasm_path")..." >&2
    "$MOONRUN_WT_BIN" --precompile "$wasm_path" -o "$cwasm_path" >&2
  fi
  echo "$cwasm_path"
}

# Run ALL (case × RUNS) check requests through a SINGLE warm
# `moonrun_wt --daemon` process. Uses the daemon's per-request
# `elapsed_us` field for timing (excludes stdin/stdout protocol
# overhead) — the cleanest signal of in-wasm work time.
#
# Cross-case amortization: `ensure_builtin_modules` (~179ms,
# #400 Option D'd to 118ms) is paid exactly once for the whole
# bench instead of once per case. Only request #1 of case #1
# is cold; all others run on a fully warmed store. Mirrors
# the host side's session-http amortization model.
#
# Args:
#   $1 = wasm path             (cwasm if available)
#   $2 = RUNS                  (per-case run count)
#   $3 = out tmp dir           ($OUT_DIR/tmp)
#   $4 = raw_tsv               (appended)
#   $5 = raw_stage_tsv         (appended)
#   $6.. = case paths          (one absolute path per case)
#
# Produces the same per-(case,run) output files the per-case loop
# body would have produced, keyed by the same `safe` prefix:
#   $OUT_DIR/raw/${safe}.check.selfhost.txt         (one elapsed_ms per line)
#   $OUT_DIR/raw/${safe}.check_stage.selfhost.${stage}.txt
#   $tmp_dir/${safe}.check.selfhost.${run}.profile.tsv
#   $tmp_dir/${safe}.check.selfhost.${run}.stdout
run_check_all_cases_daemon() {
  local wasm_path="$1"
  local runs="$2"
  local tmp_dir="$3"
  local raw_tsv="$4"
  local raw_stage_tsv="$5"
  shift 5
  local -a cases=("$@")

  # Reset per-case output files for all cases up-front. The demux
  # loop below appends, so a stale file from a prior run would
  # corrupt the median.
  local case_path rel_case safe
  for case_path in "${cases[@]}"; do
    rel_case="${case_path#$PROJECT_ROOT/}"
    safe="$(echo "$rel_case" | tr '/: ' '___')"
    : > "$OUT_DIR/raw/${safe}.check.selfhost.txt"
    for stage in load type total; do
      : > "$OUT_DIR/raw/${safe}.check_stage.selfhost.${stage}.txt"
    done
  done

  # Build one giant request stream covering every (case × run).
  # Each request's --profile-tsv path is unique per (case, run)
  # so we can demux profile data after the daemon completes.
  # Iteration order is case-major (case1 × runs, then case2 × runs)
  # — important when interpreting the cold-request outlier: only
  # the very first request of case 1 sees a fully-cold store.
  local req_file="${tmp_dir}/check.daemon.all.requests.jsonl"
  local resp_file="${tmp_dir}/check.daemon.all.responses.jsonl"
  : > "$req_file"
  for case_path in "${cases[@]}"; do
    rel_case="${case_path#$PROJECT_ROOT/}"
    safe="$(echo "$rel_case" | tr '/: ' '___')"
    local run_idx=1
    while [ "$run_idx" -le "$runs" ]; do
      local profile_file="${tmp_dir}/${safe}.check.selfhost.${run_idx}.profile.tsv"
      # JSON-encode args via python so paths with shell-unsafe
      # chars (spaces, quotes) round-trip cleanly.
      python3 -c "import json,sys; print(json.dumps({'args':sys.argv[1:]}))" \
        --check --profile-tsv "$profile_file" --file "$case_path" >> "$req_file"
      run_idx=$((run_idx + 1))
    done
  done

  # Run the single daemon. Failure aborts — a per-case fallback
  # would silently mask daemon regressions.
  if ! "$MOONRUN_WT_BIN" --daemon "$wasm_path" < "$req_file" > "$resp_file" 2>"${tmp_dir}/check.daemon.all.stderr"; then
    echo "bench-selfhost-perf: cross-case daemon run failed; stderr at ${tmp_dir}/check.daemon.all.stderr" >&2
    exit 1
  fi

  # Demux responses back to per-(case, run) files. Response order
  # matches request order, so case_idx = i / runs, run_idx = i % runs + 1.
  python3 - "$resp_file" "$tmp_dir" "$OUT_DIR" "$runs" "${cases[@]}" <<'PY'
import json, os, sys
resp_file, tmp_dir, out_dir, runs_s = sys.argv[1:5]
runs = int(runs_s)
case_paths = sys.argv[5:]
project_root = os.environ.get("PROJECT_ROOT", "")

def safe_for(case_path: str) -> str:
    rel = case_path[len(project_root) + 1:] if case_path.startswith(project_root + "/") else case_path
    return rel.replace("/", "_").replace(":", "_").replace(" ", "_")

# Open sample files per case.
sample_files = {}
for case_path in case_paths:
    safe = safe_for(case_path)
    sample_files[safe] = open(os.path.join(out_dir, "raw", f"{safe}.check.selfhost.txt"), "w")

with open(resp_file) as rf:
    for i, line in enumerate(rf):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        case_idx = i // runs
        run_idx = i % runs + 1
        if case_idx >= len(case_paths):
            sys.stderr.write(f"bench-selfhost-perf: extra daemon response #{i+1}, no matching request\n")
            sys.exit(1)
        case_path = case_paths[case_idx]
        safe = safe_for(case_path)
        if d.get("exit_code", 0) != 0 or "error" in d:
            sys.stderr.write(
                f"bench-selfhost-perf: daemon req {i+1} (case={case_path} run={run_idx}) "
                f"non-zero exit: {d.get('exit_code')} err={d.get('error','?')}\n"
            )
            sys.exit(1)
        elapsed_us = int(d["elapsed_us"])
        elapsed_ms = elapsed_us // 1000
        sample_files[safe].write(f"{elapsed_ms}\n")
        # Write per-iteration captured stdout (matches run_timed).
        with open(os.path.join(tmp_dir, f"{safe}.check.selfhost.{run_idx}.stdout"), "w") as so:
            so.write(d.get("stdout", ""))
        # Empty stderr to match per-iteration convention.
        open(os.path.join(tmp_dir, f"{safe}.check.selfhost.{run_idx}.stderr"), "w").close()

for f in sample_files.values():
    f.close()
PY

  # Append raw_tsv + raw_stage_tsv rows, mirroring the main loop's
  # per-case bookkeeping so downstream aggregation sees identical
  # structure.
  for case_path in "${cases[@]}"; do
    rel_case="${case_path#$PROJECT_ROOT/}"
    safe="$(echo "$rel_case" | tr '/: ' '___')"
    local sample_file="$OUT_DIR/raw/${safe}.check.selfhost.txt"
    local run_idx=1
    while [ "$run_idx" -le "$runs" ]; do
      local elapsed
      elapsed="$(sed -n "${run_idx}p" "$sample_file")"
      printf "%s\t%s\t%s\t%d\t%s\t%s\n" "$rel_case" "check" "selfhost" "$run_idx" "$elapsed" "0" >> "$raw_tsv"
      local profile_file="${tmp_dir}/${safe}.check.selfhost.${run_idx}.profile.tsv"
      if [ ! -f "$profile_file" ]; then
        echo "bench-selfhost-perf: missing stage profile (check/selfhost daemon): $rel_case run=$run_idx" >&2
        exit 1
      fi
      while IFS=$'\t' read -r stage ms us; do
        if [ "$stage" = "stage" ] || [ -z "$stage" ]; then continue; fi
        if [ -z "$us" ]; then us="$((ms * 1000))"; fi
        printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\n" "$rel_case" "check" "selfhost" "$run_idx" "$stage" "$ms" "$us" >> "$raw_stage_tsv"
        echo "$us" >> "$OUT_DIR/raw/${safe}.check_stage.selfhost.${stage}.txt"
      done < "$profile_file"
      run_idx=$((run_idx + 1))
    done
  done
}

# Dispatch a stage1 wasm invocation to the configured runtime.
# Usage: selfhost_runner <wasm-or-cwasm> [args...]
selfhost_runner() {
  case "$SELFHOST_RUNTIME" in
    moonrun)
      moonrun "$@"
      ;;
    wasmtime|wasmtime-aot|moonrun-wt|moonrun-wt-aot)
      "$MOONRUN_WT_BIN" "$@"
      ;;
    *)
      echo "bench-selfhost-perf: unknown runtime $SELFHOST_RUNTIME" >&2
      return 2
      ;;
  esac
}

main() {
  if ! is_positive_int "$RUNS"; then
    echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_RUNS must be positive integer" >&2
    exit 1
  fi
  if [ "$COMPILE_MODE" != "e2e" ] && [ "$COMPILE_MODE" != "in-memory" ]; then
    echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_COMPILE_MODE must be e2e or in-memory" >&2
    exit 1
  fi

  ensure_binaries

  mkdir -p "$OUT_DIR/raw" "$OUT_DIR/tmp"
  local raw_tsv="$OUT_DIR/raw.${COMPILE_MODE}.tsv"
  local summary_tsv="$OUT_DIR/summary.${COMPILE_MODE}.tsv"
  local raw_stage_tsv="$OUT_DIR/raw_stage.${COMPILE_MODE}.tsv"
  local stage_summary_tsv="$OUT_DIR/stage_summary.${COMPILE_MODE}.tsv"
  : > "$raw_tsv"
  printf "file\tphase\truntime\trun\telapsed_ms\tstatus\n" >> "$raw_tsv"
  : > "$raw_stage_tsv"
  printf "file\tphase\truntime\trun\tstage\telapsed_ms\telapsed_us\n" >> "$raw_stage_tsv"

  local cases=()
  while IFS= read -r p; do
    cases+=("$p")
  done < <(collect_cases "$@")

  if [ "${#cases[@]}" -eq 0 ]; then
    echo "bench-selfhost-perf: no cases resolved" >&2
    exit 1
  fi

  echo "[selfhost-perf] cases=${#cases[@]} runs=${RUNS}"
  echo "[selfhost-perf] compile_mode=${COMPILE_MODE}"
  echo "[selfhost-perf] selfhost_wasm_profile=${SELFHOST_WASM_PROFILE}"

  # Warm-up pass: moonrun's first invocation on a stage1 wasm pays a
  # JIT-compile cost (observed locally as a 7× outlier on the first
  # case — `examples/basics.vibe` selfhost compile = 1771ms vs ~250ms
  # for subsequent cases). Run each stage1 wasm once before the timed
  # loop so the measurement loop sees only warm runs. Output is
  # discarded to /dev/null; failure during warm-up is tolerated since
  # the measurement loop will re-surface any genuine errors.
  local warmup_case="${cases[0]}"
  echo "[selfhost-perf] warmup: ${warmup_case#$PROJECT_ROOT/}"
  echo "[selfhost-perf] runtime=$(runtime_label)"
  selfhost_runner "$STAGE1_COMPILER_WASM" compile-lite --wasm-linear --no-dce --in-memory "$warmup_case" >/dev/null 2>&1 || true
  selfhost_runner "$STAGE1_CHECKER_WASM" --check --file "$warmup_case" >/dev/null 2>&1 || true

  # Cross-case daemon pre-pass: one warm wasm instance handles ALL
  # (case × run) check/selfhost requests, so `ensure_builtin_modules`
  # is paid exactly once for the whole bench. Pre-populates the same
  # per-(case, run) output files the per-case loop body would; the
  # loop then unconditionally skips check/selfhost since results
  # already exist.
  local check_daemon_active=0
  if [ "$CHECK_DAEMON_MODE" = "1" ] && runtime_uses_moonrun_wt; then
    check_daemon_active=1
    echo "[selfhost-perf] check/selfhost: cross-case daemon mode (1 daemon for ${#cases[@]} cases × ${RUNS} runs)"
    PROJECT_ROOT="$PROJECT_ROOT" run_check_all_cases_daemon \
      "$STAGE1_CHECKER_WASM" "$RUNS" "$OUT_DIR/tmp" \
      "$raw_tsv" "$raw_stage_tsv" "${cases[@]}"
  fi

  local case_path rel_case safe
  for case_path in "${cases[@]}"; do
    rel_case="${case_path#$PROJECT_ROOT/}"
    safe="$(echo "$rel_case" | tr '/: ' '___')"
    for phase in compile check; do
      for runtime in host selfhost; do
        # Cross-case daemon pre-pass already populated check/selfhost
        # results for this case — skip the per-iteration loop body.
        if [ "$check_daemon_active" = "1" ] \
           && [ "$phase" = "check" ] && [ "$runtime" = "selfhost" ]; then
          continue
        fi
        local run_idx=1
        local sample_file="$OUT_DIR/raw/${safe}.${phase}.${runtime}.txt"
        : > "$sample_file"
        if [ "$phase" = "compile" ]; then
          for stage in load type compile write total; do
            : > "$OUT_DIR/raw/${safe}.compile_stage.${runtime}.${stage}.txt"
          done
        else
          for stage in load type total; do
            : > "$OUT_DIR/raw/${safe}.check_stage.${runtime}.${stage}.txt"
          done
        fi
        while [ "$run_idx" -le "$RUNS" ]; do
          local stdout_file="$OUT_DIR/tmp/${safe}.${phase}.${runtime}.${run_idx}.stdout"
          local stderr_file="$OUT_DIR/tmp/${safe}.${phase}.${runtime}.${run_idx}.stderr"
          local profile_file="$OUT_DIR/tmp/${safe}.${phase}.${runtime}.${run_idx}.profile.tsv"
          local callstack_args=()
          if [ -n "$PROFILE_CALLSTACK" ] && [ "$run_idx" -eq 1 ]; then
            local callstack_file="$OUT_DIR/tmp/${safe}.${phase}.${runtime}.callstack.tsv"
            callstack_args=(--profile-callstack "$callstack_file")
          fi
          local cmd_status elapsed
          if [ "$phase" = "compile" ] && [ "$runtime" = "host" ] && [ "$COMPILE_MODE" = "e2e" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              "$VIBE_BIN" compile-lite --wasm-linear --no-dce --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path" -o "$OUT_DIR/tmp/${safe}.${run_idx}.host.wasm")
          elif [ "$phase" = "compile" ] && [ "$runtime" = "selfhost" ] && [ "$COMPILE_MODE" = "e2e" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              selfhost_runner "$STAGE1_COMPILER_WASM" compile-lite --wasm-linear --no-dce --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path" -o "$OUT_DIR/tmp/${safe}.${run_idx}.selfhost.wasm")
          elif [ "$phase" = "compile" ] && [ "$runtime" = "host" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              "$VIBE_BIN" compile-lite --wasm-linear --no-dce --in-memory --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path")
          elif [ "$phase" = "compile" ] && [ "$runtime" = "selfhost" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              selfhost_runner "$STAGE1_COMPILER_WASM" compile-lite --wasm-linear --no-dce --in-memory --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path")
          elif [ "$phase" = "check" ] && [ "$runtime" = "host" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              env VIBE_CHECK_DEBUG=0 "$VIBE_BIN" check --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path")
          else
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              selfhost_runner "$STAGE1_CHECKER_WASM" --check --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" --file "$case_path")
          fi
          printf "%s\t%s\t%s\t%d\t%s\t%s\n" "$rel_case" "$phase" "$runtime" "$run_idx" "$elapsed" "$cmd_status" >> "$raw_tsv"
          echo "$elapsed" >> "$sample_file"
          if [ "$cmd_status" -ne 0 ]; then
            echo "bench-selfhost-perf: command failed (${phase}/${runtime}): $rel_case" >&2
            echo "  stderr: $stderr_file" >&2
            exit 1
          fi
          if [ "$phase" = "compile" ] || [ "$phase" = "check" ]; then
            if [ ! -f "$profile_file" ]; then
              echo "bench-selfhost-perf: missing stage profile (${phase}/${runtime}): $rel_case" >&2
              exit 1
            fi
            while IFS=$'\t' read -r stage ms us; do
              if [ "$stage" = "stage" ] || [ -z "$stage" ]; then
                continue
              fi
              if [ -z "$us" ]; then
                us="$((ms * 1000))"
              fi
              printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\n" "$rel_case" "$phase" "$runtime" "$run_idx" "$stage" "$ms" "$us" >> "$raw_stage_tsv"
              echo "$us" >> "$OUT_DIR/raw/${safe}.${phase}_stage.${runtime}.${stage}.txt"
            done < "$profile_file"
          fi
          run_idx=$((run_idx + 1))
        done
      done
    done
  done

  printf "file\tcompile_host_ms\tcompile_selfhost_ms\tcompile_ratio\tcheck_host_ms\tcheck_selfhost_ms\tcheck_ratio\n" > "$summary_tsv"
  printf "file\tphase\tstage\thost_us\tselfhost_us\tratio\n" > "$stage_summary_tsv"

  local sum_compile_host=0
  local sum_compile_self=0
  local sum_check_host=0
  local sum_check_self=0
  local fail_ratio=0

  for case_path in "${cases[@]}"; do
    rel_case="${case_path#$PROJECT_ROOT/}"
    safe="$(echo "$rel_case" | tr '/: ' '___')"
    local chost cself khost kself cratio kratio
    chost="$(median_file_ms "$OUT_DIR/raw/${safe}.compile.host.txt")"
    cself="$(median_file_ms "$OUT_DIR/raw/${safe}.compile.selfhost.txt")"
    khost="$(median_file_ms "$OUT_DIR/raw/${safe}.check.host.txt")"
    kself="$(median_file_ms "$OUT_DIR/raw/${safe}.check.selfhost.txt")"
    cratio="$(calc_ratio "$cself" "$chost")"
    kratio="$(calc_ratio "$kself" "$khost")"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rel_case" "$chost" "$cself" "$cratio" "$khost" "$kself" "$kratio" >> "$summary_tsv"

    sum_compile_host=$((sum_compile_host + chost))
    sum_compile_self=$((sum_compile_self + cself))
    sum_check_host=$((sum_check_host + khost))
    sum_check_self=$((sum_check_self + kself))

    if [ -n "$MAX_CASE_COMPILE_RATIO" ] && ratio_exceeds "$cratio" "$MAX_CASE_COMPILE_RATIO"; then
      echo "bench-selfhost-perf: per-case compile ratio exceeded ($rel_case: $cratio > $MAX_CASE_COMPILE_RATIO)" >&2
      fail_ratio=1
    fi
    if [ -n "$MAX_CASE_CHECK_RATIO" ] && ratio_exceeds "$kratio" "$MAX_CASE_CHECK_RATIO"; then
      echo "bench-selfhost-perf: per-case check ratio exceeded ($rel_case: $kratio > $MAX_CASE_CHECK_RATIO)" >&2
      fail_ratio=1
    fi

    for phase in compile check; do
      while IFS= read -r stage; do
        [ -z "$stage" ] && continue
        local stage_host_file="$OUT_DIR/raw/${safe}.${phase}_stage.host.${stage}.txt"
        local stage_self_file="$OUT_DIR/raw/${safe}.${phase}_stage.selfhost.${stage}.txt"
        if [ -f "$stage_host_file" ] && [ -f "$stage_self_file" ]; then
          local stage_host stage_self stage_ratio
          stage_host="$(median_file_ms "$stage_host_file")"
          stage_self="$(median_file_ms "$stage_self_file")"
          stage_ratio="$(calc_ratio "$stage_self" "$stage_host")"
          printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$rel_case" "$phase" "$stage" "$stage_host" "$stage_self" "$stage_ratio" >> "$stage_summary_tsv"
        fi
      done < <(awk -F'\t' -v file="$rel_case" -v phase="$phase" '
        NR > 1 && $1 == file && $2 == phase { print $5 }
      ' "$raw_stage_tsv" | sort -u)
    done
  done

  local total_compile_ratio total_check_ratio
  total_compile_ratio="$(calc_ratio "$sum_compile_self" "$sum_compile_host")"
  total_check_ratio="$(calc_ratio "$sum_check_self" "$sum_check_host")"

  # `column` ships with bsdmainutils on Debian; not always present on minimal
  # build images. Fall back to raw TSV if missing.
  pretty_tsv() {
    if command -v column >/dev/null 2>&1; then
      column -t -s $'\t'
    else
      cat
    fi
  }

  echo
  echo "=== selfhost perf summary (median ms) ==="
  pretty_tsv <"$summary_tsv"
  echo
  echo "TOTAL compile(host/selfhost): ${sum_compile_host} / ${sum_compile_self} ms (ratio=${total_compile_ratio})"
  echo "TOTAL check(host/selfhost):   ${sum_check_host} / ${sum_check_self} ms (ratio=${total_check_ratio})"
  echo "raw:     $raw_tsv"
  echo "summary: $summary_tsv"
  if [ -s "$stage_summary_tsv" ]; then
    echo "stage summary:"
    pretty_tsv <"$stage_summary_tsv"
    echo
    echo "top selfhost hotspots:"
    {
      printf "file\tphase\tstage\tselfhost_us\tratio\n"
      tail -n +2 "$stage_summary_tsv" | sort -t $'\t' -k5,5nr | head -n 8 | awk -F'\t' '{ printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $5, $6 }'
    } | pretty_tsv
    echo
    echo "worst selfhost ratios:"
    {
      printf "file\tphase\tstage\thost_us\tselfhost_us\tratio\n"
      tail -n +2 "$stage_summary_tsv" | sort -t $'\t' -k6,6nr | head -n 8
    } | pretty_tsv
    echo "raw stage:     $raw_stage_tsv"
    echo "stage summary: $stage_summary_tsv"
  fi

  if [ -n "$MAX_TOTAL_COMPILE_RATIO" ] && ratio_exceeds "$total_compile_ratio" "$MAX_TOTAL_COMPILE_RATIO"; then
    echo "bench-selfhost-perf: total compile ratio exceeded (${total_compile_ratio} > ${MAX_TOTAL_COMPILE_RATIO})" >&2
    fail_ratio=1
  fi
  if [ -n "$MAX_TOTAL_CHECK_RATIO" ] && ratio_exceeds "$total_check_ratio" "$MAX_TOTAL_CHECK_RATIO"; then
    echo "bench-selfhost-perf: total check ratio exceeded (${total_check_ratio} > ${MAX_TOTAL_CHECK_RATIO})" >&2
    fail_ratio=1
  fi

  if [ "$fail_ratio" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
