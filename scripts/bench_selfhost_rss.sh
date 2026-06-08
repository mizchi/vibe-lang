#!/usr/bin/env bash
# Peak-RSS gate for the selfhost cutover (#402).
#
# Measures peak resident set size (getrusage RUSAGE_CHILDREN.ru_maxrss) of
#   host    = release native `vibe.exe`
#   selfhost = src/ runtime_compile built to wasm, run via moonrun_wt with a
#              PRECOMPILED .cwasm (wasmtime-AOT)
# for the same `compile-lite --wasm-linear --no-dce` / `check` commands the perf
# harness (scripts/bench_selfhost_perf.sh) uses, over the KPI cases, and reports
# the selfhost/host peak-RSS ratio for compile and check.
#
# IMPORTANT: the gate is defined against the wasmtime-AOT path. Running the raw
# `.wasm` through moonrun_wt JITs the module at startup, which inflates RSS ~8x
# with transient Cranelift codegen memory — NOT representative of a deployed
# artifact. This script always precompiles to `.cwasm` first.
#
# Usage:
#   scripts/bench_selfhost_rss.sh            # report-only
#   scripts/bench_selfhost_rss.sh --gate     # exit 1 if a TOTAL ratio exceeds cap
#   VIBE_SELFHOST_RSS_MAX_RATIO=2.0 ...       # gate cap (default 2.0)
#   VIBE_SELFHOST_RSS_CASES_FILE=...          # case list (default kpi_cases.txt)
#   VIBE_SELFHOST_RSS_PROFILE=release|debug   # selfhost wasm profile (default release)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

GATE=0
for a in "$@"; do
  case "$a" in
    --gate) GATE=1 ;;
    *) echo "bench-selfhost-rss: unknown arg: $a" >&2; exit 2 ;;
  esac
done

MAX_RATIO="${VIBE_SELFHOST_RSS_MAX_RATIO:-2.0}"
PROFILE="${VIBE_SELFHOST_RSS_PROFILE:-release}"
CASES_FILE="${VIBE_SELFHOST_RSS_CASES_FILE:-$PROJECT_ROOT/bench/selfhost_perf/kpi_cases.txt}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_rss}"
MOONRUN_WT_BIN="${MOONRUN_WT_BIN:-$PROJECT_ROOT/tools/moonrun_wasmtime/target/release/moonrun_wt}"
COMPILER_WASM="$PROJECT_ROOT/_build/wasm/$PROFILE/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
CHECKER_WASM="$PROJECT_ROOT/_build/wasm/$PROFILE/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"

mkdir -p "$OUT_DIR/tmp"

command -v python3 >/dev/null 2>&1 || { echo "bench-selfhost-rss: python3 required" >&2; exit 2; }

# --- ensure binaries ---
# Reuse a caller-provided release CLI (e.g. CI's downloaded artifact) instead of
# rebuilding it; only fall back to ensure_native_cli.sh when VIBE_BIN is unset.
if [ -z "${VIBE_BIN:-}" ] || [ ! -x "${VIBE_BIN:-/nonexistent}" ]; then
  VIBE_CLI_RELEASE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
  VIBE_BIN="${VIBE_BIN:-$VIBE_CLI_BIN}"
fi

build_wasm() {
  local pkg="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "[rss] building $pkg ($PROFILE)..." >&2
    if [ "$PROFILE" = "release" ]; then
      moon build --target wasm --release "$pkg" >&2
    else
      moon build --target wasm "$pkg" >&2
    fi
  fi
}
build_wasm src/cmd/vibe_compile_wasi "$COMPILER_WASM"
build_wasm src/cmd/vibe_check_wasi "$CHECKER_WASM"

if [ ! -x "$MOONRUN_WT_BIN" ]; then
  echo "[rss] building moonrun_wt..." >&2
  (cd "$PROJECT_ROOT/tools/moonrun_wasmtime" && cargo build --release >&2)
fi
[ -x "$MOONRUN_WT_BIN" ] || { echo "bench-selfhost-rss: moonrun_wt missing: $MOONRUN_WT_BIN" >&2; exit 2; }

# --- AOT precompile (the gate is defined against this path) ---
COMPILER_CWASM="$OUT_DIR/compiler.cwasm"
CHECKER_CWASM="$OUT_DIR/checker.cwasm"
"$MOONRUN_WT_BIN" --precompile "$COMPILER_WASM" -o "$COMPILER_CWASM" >&2
"$MOONRUN_WT_BIN" --precompile "$CHECKER_WASM" -o "$CHECKER_CWASM" >&2

# --- peak-RSS helper: runs argv, prints child ru_maxrss (KB) ---
RSS_PY="$OUT_DIR/rss_of.py"
cat > "$RSS_PY" <<'PY'
import sys, subprocess, resource
r = subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
PY

rss() {
  # measure one command in a fresh python so ru_maxrss is that child's peak
  python3 "$RSS_PY" "$@" 2>/dev/null | tail -1
}

# --- enumerate cases ---
declare -a CASES=()
while IFS= read -r row; do
  case "$row" in ''|\#*) continue ;; esac
  [ -f "$row" ] && CASES+=("$row")
done < "$CASES_FILE"
[ "${#CASES[@]}" -gt 0 ] || { echo "bench-selfhost-rss: no cases in $CASES_FILE" >&2; exit 2; }

echo "[rss] profile=$PROFILE cases=${#CASES[@]} runtime=wasmtime-aot (cwasm)"
printf "%-44s %10s %10s %7s | %10s %10s %7s\n" "case" "C.host" "C.self" "ratio" "K.host" "K.self" "ratio"

sum_ch=0; sum_cs=0; sum_kh=0; sum_ks=0
for c in "${CASES[@]}"; do
  ch=$(rss "$VIBE_BIN" compile-lite --wasm-linear --no-dce "$c" -o "$OUT_DIR/tmp/h.wasm")
  cs=$(rss "$MOONRUN_WT_BIN" "$COMPILER_CWASM" compile-lite --wasm-linear --no-dce "$c" -o "$OUT_DIR/tmp/s.wasm")
  kh=$(VIBE_CHECK_DEBUG=0 rss "$VIBE_BIN" check "$c")
  ks=$(rss "$MOONRUN_WT_BIN" "$CHECKER_CWASM" --check --file "$c")
  cr=$(python3 -c "print(f'{$cs/$ch:.2f}')" 2>/dev/null || echo "n/a")
  kr=$(python3 -c "print(f'{$ks/$kh:.2f}')" 2>/dev/null || echo "n/a")
  printf "%-44s %10s %10s %7s | %10s %10s %7s\n" "$c" "$ch" "$cs" "$cr" "$kh" "$ks" "$kr"
  sum_ch=$((sum_ch+ch)); sum_cs=$((sum_cs+cs)); sum_kh=$((sum_kh+kh)); sum_ks=$((sum_ks+ks))
done

total_cr=$(python3 -c "print(f'{$sum_cs/$sum_ch:.3f}')")
total_kr=$(python3 -c "print(f'{$sum_ks/$sum_kh:.3f}')")
echo "==================== selfhost peak-RSS (wasmtime-AOT) ===================="
echo "  TOTAL compile peak-RSS ratio (self/host): ${total_cr}x"
echo "  TOTAL check   peak-RSS ratio (self/host): ${total_kr}x"
echo "  gate cap: ${MAX_RATIO}x"
echo "========================================================================="

if [ "$GATE" -eq 1 ]; then
  over=$(python3 -c "print(1 if ($total_cr > $MAX_RATIO or $total_kr > $MAX_RATIO) else 0)")
  if [ "$over" = "1" ]; then
    echo "  RSS GATE FAIL: a TOTAL ratio exceeds ${MAX_RATIO}x" >&2
    exit 1
  fi
  echo "  RSS gate OK (both ratios <= ${MAX_RATIO}x)"
fi
exit 0
