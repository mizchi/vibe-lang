#!/usr/bin/env bash
# Measure host vs selfhost peak RSS and wallclock for compile/check phases.
#
# - hyperfine: stable wallclock + std-dev (export JSON)
# - /usr/bin/time -v: peak resident-set size (Maximum RSS, KB)
#
# Default cases mirror bench/selfhost_perf/cases.txt; override via
# VIBE_SELFHOST_MEMORY_CASES_FILE or pass paths as arguments.
#
# Usage:
#   scripts/bench_selfhost_memory.sh [path...]
#
# Env knobs:
#   VIBE_SELFHOST_MEMORY_RUNS         hyperfine --runs (default: 3)
#   VIBE_SELFHOST_MEMORY_WARMUP       hyperfine --warmup (default: 1)
#   VIBE_SELFHOST_MEMORY_TIME_RUNS    /usr/bin/time -v repeats (default: 3, max kept)
#   VIBE_SELFHOST_MEMORY_PHASES       comma-separated subset of: compile,check (default: both)
#   VIBE_SELFHOST_MEMORY_RUNTIMES     comma-separated subset of: host,selfhost (default: both)
#   VIBE_SELFHOST_MEMORY_WASM_PROFILE debug|release (default: debug)
#   VIBE_SELFHOST_MEMORY_REBUILD      auto|always|never (default: auto)
#   VIBE_SELFHOST_MEMORY_OUT_DIR      output dir (default: _build/bench/selfhost_memory)
#   VIBE_SELFHOST_MEMORY_MAX_RSS_RATIO   abort if any selfhost/host RSS ratio exceeds this
#   VIBE_SELFHOST_MEMORY_MAX_RSS_KB      abort if any peak RSS (KB) exceeds this absolute limit
#   VIBE_SELFHOST_MEMORY_SKIP_HYPERFINE   1 to skip hyperfine pass (RSS only)
#   VIBE_SELFHOST_MEMORY_RUNTIME      moonrun|wasmtime|wasmtime-aot (default: moonrun)
#                                     wasmtime-aot pre-compiles stage1 wasm → cwasm
#                                     and runs through tools/moonrun_wasmtime.
#   VIBE_SELFHOST_MEMORY_WASM_OPT_LEVEL
#                                     auto (default) picks -Oz for moonrun,
#                                     -O3 for wasmtime/-aot. Override with
#                                     an explicit level (-Oz|-O3|-O4|...).
#   MOONRUN_WT_BIN                    path to a prebuilt moonrun_wt binary
set -euo pipefail

trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"

WASM_PROFILE="${VIBE_SELFHOST_MEMORY_WASM_PROFILE:-debug}"
REBUILD_MODE="${VIBE_SELFHOST_MEMORY_REBUILD:-auto}"
USE_WASM_OPT="${VIBE_SELFHOST_MEMORY_WASM_OPT:-auto}"
case "$USE_WASM_OPT" in 1|yes|on|true|auto|0|no|off|false) ;;
  *) echo "bench-selfhost-memory: VIBE_SELFHOST_MEMORY_WASM_OPT must be auto|on|off" >&2; exit 1 ;;
esac
COMPILER_WASM_RAW="$ROOT_DIR/_build/wasm/$WASM_PROFILE/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
CHECKER_WASM_RAW="$ROOT_DIR/_build/wasm/$WASM_PROFILE/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
COMPILER_WASM_OPT="$ROOT_DIR/_build/wasm/opt/vibe_compile_wasi.wasm"
CHECKER_WASM_OPT="$ROOT_DIR/_build/wasm/opt/vibe_check_wasi.wasm"
COMPILER_WASM="$COMPILER_WASM_RAW"
CHECKER_WASM="$CHECKER_WASM_RAW"
VIBE_BIN="${VIBE_BIN:-$VIBE_CLI_BIN}"
OUT_DIR="${VIBE_SELFHOST_MEMORY_OUT_DIR:-$ROOT_DIR/_build/bench/selfhost_memory}"
CASES_FILE="${VIBE_SELFHOST_MEMORY_CASES_FILE:-$ROOT_DIR/bench/selfhost_perf/cases.txt}"
RUNS="${VIBE_SELFHOST_MEMORY_RUNS:-3}"
WARMUP="${VIBE_SELFHOST_MEMORY_WARMUP:-1}"
TIME_RUNS="${VIBE_SELFHOST_MEMORY_TIME_RUNS:-3}"
PHASES_RAW="${VIBE_SELFHOST_MEMORY_PHASES:-compile,check}"
RUNTIMES_RAW="${VIBE_SELFHOST_MEMORY_RUNTIMES:-host,selfhost}"
MAX_RSS_RATIO="${VIBE_SELFHOST_MEMORY_MAX_RSS_RATIO:-}"
MAX_RSS_KB="${VIBE_SELFHOST_MEMORY_MAX_RSS_KB:-}"
SKIP_HYPERFINE="${VIBE_SELFHOST_MEMORY_SKIP_HYPERFINE:-0}"
SELFHOST_RUNTIME="${VIBE_SELFHOST_MEMORY_RUNTIME:-moonrun}"
MOONRUN_WT_BIN="${MOONRUN_WT_BIN:-}"
case "$SELFHOST_RUNTIME" in moonrun|wasmtime|wasmtime-aot) ;;
  *) echo "bench-selfhost-memory: VIBE_SELFHOST_MEMORY_RUNTIME must be moonrun|wasmtime|wasmtime-aot" >&2; exit 1 ;;
esac

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

if ! is_positive_int "$RUNS"; then
  echo "bench-selfhost-memory: VIBE_SELFHOST_MEMORY_RUNS must be positive integer" >&2
  exit 1
fi
if ! is_positive_int "$TIME_RUNS"; then
  echo "bench-selfhost-memory: VIBE_SELFHOST_MEMORY_TIME_RUNS must be positive integer" >&2
  exit 1
fi

IFS=',' read -ra PHASES <<< "$PHASES_RAW"
IFS=',' read -ra RUNTIMES <<< "$RUNTIMES_RAW"
for ph in "${PHASES[@]}"; do
  case "$ph" in compile|check) ;;
    *) echo "bench-selfhost-memory: unknown phase '$ph'" >&2; exit 1 ;;
  esac
done
for rt in "${RUNTIMES[@]}"; do
  case "$rt" in host|selfhost) ;;
    *) echo "bench-selfhost-memory: unknown runtime '$rt'" >&2; exit 1 ;;
  esac
done

case "$REBUILD_MODE" in auto|always|never) ;;
  *) echo "bench-selfhost-memory: VIBE_SELFHOST_MEMORY_REBUILD must be auto|always|never" >&2; exit 1 ;;
esac
case "$WASM_PROFILE" in debug|release) ;;
  *) echo "bench-selfhost-memory: VIBE_SELFHOST_MEMORY_WASM_PROFILE must be debug|release" >&2; exit 1 ;;
esac

source_changed_since() {
  local artifact="$1"
  find "$ROOT_DIR/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$ROOT_DIR" -maxdepth 1 -type f \( -name 'moon.mod' -o -name 'moon.mod.json' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q .
}

ensure_binaries() {
  local need_compiler=0
  local need_checker=0
  if [ "$REBUILD_MODE" = "always" ]; then
    need_compiler=1
    need_checker=1
  elif [ "$REBUILD_MODE" = "auto" ]; then
    if [ ! -f "$COMPILER_WASM" ] || source_changed_since "$COMPILER_WASM"; then
      need_compiler=1
    fi
    if [ ! -f "$CHECKER_WASM" ] || source_changed_since "$CHECKER_WASM"; then
      need_checker=1
    fi
  fi
  local needs_selfhost=0
  for rt in "${RUNTIMES[@]}"; do
    if [ "$rt" = "selfhost" ]; then needs_selfhost=1; fi
  done
  if [ "$needs_selfhost" -eq 1 ]; then
    local needs_compile=0
    local needs_check=0
    for ph in "${PHASES[@]}"; do
      [ "$ph" = "compile" ] && needs_compile=1
      [ "$ph" = "check" ] && needs_check=1
    done
    if [ "$needs_compile" -eq 1 ] && [ "$need_compiler" -eq 1 ]; then
      echo "[selfhost-memory] building selfhost compiler wasm ($WASM_PROFILE)..."
      if [ "$WASM_PROFILE" = "release" ]; then
        moon build --target wasm --release src/cmd/vibe_compile_wasi
      else
        moon build --target wasm src/cmd/vibe_compile_wasi
      fi
    fi
    if [ "$needs_check" -eq 1 ] && [ "$need_checker" -eq 1 ]; then
      echo "[selfhost-memory] building selfhost checker wasm ($WASM_PROFILE)..."
      if [ "$WASM_PROFILE" = "release" ]; then
        moon build --target wasm --release src/cmd/vibe_check_wasi
      else
        moon build --target wasm src/cmd/vibe_check_wasi
      fi
    fi
    # Optionally swap to wasm-opt'd artifacts.
    # Auto mode is permissive: if the helper succeeds, use opt'd wasm;
    # otherwise fall back to raw release wasm with a warning.
    local want_opt=0
    local moon_wasm_opt="${MOON_HOME:-$HOME/.moon}/bin/moon-wasm-opt"
    case "$USE_WASM_OPT" in
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
      # Pick wasm-opt level per runtime (mirrors bench_selfhost_perf.sh):
      #   moonrun       → -Oz  (v8 interp: instruction count wins)
      #   wasmtime/-aot → -O3  (Cranelift JIT: loop unrolling pays off)
      # Override with VIBE_SELFHOST_MEMORY_WASM_OPT_LEVEL=-Oz|-O3|...
      # Memory RSS is less level-sensitive than wallclock, but keeping
      # the two benches consistent avoids confusing "perf used -O3 but
      # memory used -Oz" cross-comparison artifacts.
      local opt_level="${VIBE_SELFHOST_MEMORY_WASM_OPT_LEVEL:-auto}"
      if [ "$opt_level" = "auto" ]; then
        case "$SELFHOST_RUNTIME" in
          moonrun) opt_level="-Oz" ;;
          wasmtime|wasmtime-aot) opt_level="-O3" ;;
          *) opt_level="-Oz" ;;
        esac
      fi
      local opt_marker="$ROOT_DIR/_build/wasm/opt/.opt_level"
      local rebuild_mode_for_opt="$REBUILD_MODE"
      if [ ! -f "$opt_marker" ] || [ "$(cat "$opt_marker" 2>/dev/null)" != "$opt_level" ]; then
        if [ "$rebuild_mode_for_opt" != "always" ]; then
          rebuild_mode_for_opt="always"
        fi
      fi
      if ! WASM_OPT_LEVEL="$opt_level" VIBE_SELFHOST_OPT_WASM_PROFILE="$WASM_PROFILE" VIBE_SELFHOST_OPT_WASM_REBUILD="$rebuild_mode_for_opt" bash "$ROOT_DIR/scripts/build_selfhost_wasi_opt.sh" >&2; then
        echo "bench-selfhost-memory: wasm-opt step failed; falling back to raw release wasm" >&2
      else
        if [ -f "$COMPILER_WASM_OPT" ]; then COMPILER_WASM="$COMPILER_WASM_OPT"; fi
        if [ -f "$CHECKER_WASM_OPT" ]; then CHECKER_WASM="$CHECKER_WASM_OPT"; fi
        echo "$opt_level" > "$opt_marker"
        echo "[selfhost-memory] using wasm-opt'd artifacts under _build/wasm/opt/ (level=$opt_level for runtime=$SELFHOST_RUNTIME)"
      fi
    fi
    if [ "$SELFHOST_RUNTIME" = "moonrun" ]; then
      if ! command -v moonrun >/dev/null 2>&1; then
        echo "bench-selfhost-memory: moonrun not found (required for selfhost runtime)" >&2
        exit 1
      fi
    else
      ensure_moonrun_wt
      if [ "$SELFHOST_RUNTIME" = "wasmtime-aot" ]; then
        COMPILER_WASM="$(ensure_cwasm "$COMPILER_WASM")"
        CHECKER_WASM="$(ensure_cwasm "$CHECKER_WASM")"
      fi
    fi
  fi
  if [ ! -x "$VIBE_BIN" ]; then
    echo "bench-selfhost-memory: missing host CLI: $VIBE_BIN" >&2
    exit 1
  fi
}

collect_cases() {
  if [ "$#" -gt 0 ]; then
    for p in "$@"; do
      if [ -f "$ROOT_DIR/$p" ]; then
        echo "$ROOT_DIR/$p"
      elif [ -f "$p" ]; then
        echo "$p"
      else
        echo "bench-selfhost-memory: case not found: $p" >&2
        exit 1
      fi
    done
    return
  fi
  if [ ! -f "$CASES_FILE" ]; then
    echo "bench-selfhost-memory: cases file not found: $CASES_FILE" >&2
    exit 1
  fi
  while IFS= read -r row; do
    row="${row#"${row%%[![:space:]]*}"}"
    [ -z "$row" ] && continue
    [[ "$row" == \#* ]] && continue
    if [ -f "$ROOT_DIR/$row" ]; then
      echo "$ROOT_DIR/$row"
    else
      echo "bench-selfhost-memory: case not found: $row" >&2
      exit 1
    fi
  done < "$CASES_FILE"
}

# Build a host-runner prefix for the selfhost stage1 wasm. Single
# token-ish (no quoting needed) — both moonrun and moonrun_wt take the
# wasm path as positional arg 1.
selfhost_runner_prefix() {
  case "$SELFHOST_RUNTIME" in
    moonrun) printf 'moonrun' ;;
    wasmtime|wasmtime-aot) printf '%q' "$MOONRUN_WT_BIN" ;;
    *) echo "bench-selfhost-memory: unknown runtime $SELFHOST_RUNTIME" >&2; return 2 ;;
  esac
}

build_cmd() {
  local phase="$1"
  local runtime="$2"
  local case_path="$3"
  local prefix
  prefix="$(selfhost_runner_prefix)"
  case "$phase/$runtime" in
    compile/host)
      printf '%q compile-lite --wasm-linear --no-dce --in-memory %q' "$VIBE_BIN" "$case_path" ;;
    compile/selfhost)
      printf '%s %q compile-lite --wasm-linear --no-dce --in-memory %q' "$prefix" "$COMPILER_WASM" "$case_path" ;;
    check/host)
      printf 'env VIBE_CHECK_DEBUG=0 %q check %q' "$VIBE_BIN" "$case_path" ;;
    check/selfhost)
      printf '%s %q --check --file %q' "$prefix" "$CHECKER_WASM" "$case_path" ;;
  esac
}

ensure_moonrun_wt() {
  if [ -n "${MOONRUN_WT_BIN:-}" ] && [ -x "$MOONRUN_WT_BIN" ]; then
    return 0
  fi
  local default_bin="$ROOT_DIR/tools/moonrun_wasmtime/target/release/moonrun_wt"
  if [ ! -x "$default_bin" ] || [ "$REBUILD_MODE" = "always" ]; then
    echo "[selfhost-memory] building moonrun_wt (wasmtime host)..." >&2
    (cd "$ROOT_DIR/tools/moonrun_wasmtime" && cargo build --release >&2)
  fi
  MOONRUN_WT_BIN="$default_bin"
  if [ ! -x "$MOONRUN_WT_BIN" ]; then
    echo "bench-selfhost-memory: moonrun_wt build did not produce $MOONRUN_WT_BIN" >&2
    exit 1
  fi
}

# Pre-compile stage1 `.wasm` → `.cwasm` and echo the cwasm path.
ensure_cwasm() {
  local wasm_path="$1"
  local cwasm_path="${wasm_path%.wasm}.cwasm"
  if [ ! -f "$cwasm_path" ] || [ "$wasm_path" -nt "$cwasm_path" ]; then
    echo "[selfhost-memory] AOT-compiling $(basename "$wasm_path")..." >&2
    "$MOONRUN_WT_BIN" --precompile "$wasm_path" -o "$cwasm_path" >&2
  fi
  echo "$cwasm_path"
}

# Capture max RSS (KB) from /usr/bin/time -v output. Returns the largest of
# TIME_RUNS attempts so that one-off allocator dips don't hide the high-water
# mark.
measure_max_rss_kb() {
  local cmd="$1"
  local tmp_err
  tmp_err="$(mktemp)"
  local best=0
  local i=0
  while [ "$i" -lt "$TIME_RUNS" ]; do
    if /usr/bin/time -v -o "$tmp_err" bash -c "$cmd >/dev/null 2>&1"; then
      local kb
      kb="$(awk '/Maximum resident set size/ { print $NF }' "$tmp_err" | tail -n1)"
      if [ -n "$kb" ] && [ "$kb" -gt "$best" ]; then
        best="$kb"
      fi
    else
      echo "bench-selfhost-memory: command failed during RSS sampling: $cmd" >&2
      cat "$tmp_err" >&2
      rm -f "$tmp_err"
      return 1
    fi
    i=$((i + 1))
  done
  rm -f "$tmp_err"
  echo "$best"
}

calc_ratio() {
  awk -v lhs="$1" -v rhs="$2" 'BEGIN { if (rhs == 0) { print "0.000" } else { printf "%.3f", lhs / rhs } }'
}

ratio_exceeds() {
  awk -v r="$1" -v l="$2" 'BEGIN { if (r > l) exit 0; exit 1 }'
}

main() {
  ensure_binaries
  mkdir -p "$OUT_DIR/raw" "$OUT_DIR/hyperfine"

  local cases=()
  while IFS= read -r p; do
    cases+=("$p")
  done < <(collect_cases "$@")
  if [ "${#cases[@]}" -eq 0 ]; then
    echo "bench-selfhost-memory: no cases resolved" >&2
    exit 1
  fi

  local rss_tsv="$OUT_DIR/rss_summary.tsv"
  : > "$rss_tsv"
  printf "file\tphase\thost_rss_kb\tselfhost_rss_kb\tratio\n" >> "$rss_tsv"

  echo "[selfhost-memory] cases=${#cases[@]} phases=${PHASES_RAW} runtimes=${RUNTIMES_RAW}"
  echo "[selfhost-memory] runtime=${SELFHOST_RUNTIME}"
  echo "[selfhost-memory] rss_runs=${TIME_RUNS} hyperfine_runs=${RUNS} warmup=${WARMUP}"

  local fail=0
  for case_path in "${cases[@]}"; do
    local rel="${case_path#$ROOT_DIR/}"
    local safe
    safe="$(echo "$rel" | tr '/: ' '___')"

    for phase in "${PHASES[@]}"; do
      declare -A rss=()
      for runtime in "${RUNTIMES[@]}"; do
        local cmd
        cmd="$(build_cmd "$phase" "$runtime" "$case_path")"
        echo "[selfhost-memory] rss ${phase}/${runtime} ${rel}"
        local kb
        if ! kb="$(measure_max_rss_kb "$cmd")"; then
          fail=1
          continue
        fi
        rss[$runtime]="$kb"
        echo "$kb" > "$OUT_DIR/raw/${safe}.${phase}.${runtime}.rss_kb.txt"
        if [ -n "$MAX_RSS_KB" ] && [ "$kb" -gt "$MAX_RSS_KB" ]; then
          echo "bench-selfhost-memory: peak RSS ${kb} KB exceeded MAX_RSS_KB=${MAX_RSS_KB} (${phase}/${runtime} ${rel})" >&2
          fail=1
        fi
      done
      local host_kb="${rss[host]:-0}"
      local self_kb="${rss[selfhost]:-0}"
      local ratio
      ratio="$(calc_ratio "$self_kb" "$host_kb")"
      printf "%s\t%s\t%s\t%s\t%s\n" "$rel" "$phase" "$host_kb" "$self_kb" "$ratio" >> "$rss_tsv"
      if [ -n "$MAX_RSS_RATIO" ] && [ "$host_kb" -gt 0 ] && [ "$self_kb" -gt 0 ] && ratio_exceeds "$ratio" "$MAX_RSS_RATIO"; then
        echo "bench-selfhost-memory: RSS ratio ${ratio} exceeded MAX=${MAX_RSS_RATIO} (${phase} ${rel})" >&2
        fail=1
      fi
      unset rss
    done

    if [ "$SKIP_HYPERFINE" != "1" ] && command -v hyperfine >/dev/null 2>&1; then
      for phase in "${PHASES[@]}"; do
        local args=()
        for runtime in "${RUNTIMES[@]}"; do
          local cmd
          cmd="$(build_cmd "$phase" "$runtime" "$case_path")"
          args+=("-n" "${runtime}" "$cmd >/dev/null")
        done
        local json="$OUT_DIR/hyperfine/${safe}.${phase}.json"
        echo "[selfhost-memory] hyperfine ${phase} ${rel}"
        hyperfine \
          --warmup "$WARMUP" \
          --runs "$RUNS" \
          --export-json "$json" \
          "${args[@]}"
      done
    fi
  done

  echo
  echo "=== peak RSS (KB) ==="
  column -t -s $'\t' "$rss_tsv"
  echo "rss summary: $rss_tsv"
  if [ "$SKIP_HYPERFINE" != "1" ] && command -v hyperfine >/dev/null 2>&1; then
    echo "hyperfine json: $OUT_DIR/hyperfine/"
  elif [ "$SKIP_HYPERFINE" != "1" ]; then
    echo "hyperfine not found; only RSS measured" >&2
  fi

  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
