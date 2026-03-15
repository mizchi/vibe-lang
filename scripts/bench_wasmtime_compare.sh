#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

# wasmtime 上で MoonBit wasm-gc vs Selfhost WASM を比較するベンチマーク
# vibe_check (型チェック) を同じ .vibe ファイルで実行して計測

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

MOONBIT_GC="${MOONBIT_GC:-$PROJECT_ROOT/_build/wasm-gc/release/build/lib/lib.wasm}"
SELFHOST_CHECKER="${SELFHOST_CHECKER:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm}"
RUNS="${RUNS:-5}"

CASES=(
  "$PROJECT_ROOT/examples/basics.vibe"
  "$PROJECT_ROOT/bench/compiler_size/cases/base64.vibe"
  "$PROJECT_ROOT/bench/compiler_size/cases/effects.vibe"
)

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime not found" >&2
  exit 1
fi

# Build if needed
if [ ! -f "$MOONBIT_GC" ]; then
  echo "[build] MoonBit wasm-gc release..."
  (cd "$PROJECT_ROOT" && moon build --target wasm-gc --release src/lib)
fi
if [ ! -f "$SELFHOST_CHECKER" ]; then
  echo "[build] Selfhost checker WASM..."
  (cd "$PROJECT_ROOT" && moon build --target wasm --debug src/cmd/vibe_check_wasi)
fi

now_us() {
  perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000000)'
}

echo "=== wasmtime benchmark: MoonBit wasm-gc vs Selfhost MVP ==="
echo "runs=$RUNS"
echo ""
printf "%-50s %12s %12s %8s\n" "file" "moonbit_us" "selfhost_us" "ratio"
printf "%-50s %12s %12s %8s\n" "----" "----------" "-----------" "-----"

for case_path in "${CASES[@]}"; do
  if [ ! -f "$case_path" ]; then
    continue
  fi
  rel_case="${case_path#$PROJECT_ROOT/}"
  source_content="$(cat "$case_path")"
  source_len=${#source_content}

  # MoonBit wasm-gc: vibe_check(source_ptr, source_len, out_ptr, out_cap)
  # Write source to memory at offset 1024, output at 4096+
  moonbit_times=()
  for ((i=1; i<=RUNS; i++)); do
    start=$(now_us)
    wasmtime run \
      -W gc=y \
      -W function-references=y \
      -W unknown-imports-default=y \
      --invoke vibe_check \
      "$MOONBIT_GC" \
      1024 0 $((65536)) $((65536)) >/dev/null 2>&1 || true
    end=$(now_us)
    moonbit_times+=($((end - start)))
  done

  # Selfhost WASM: moonrun check
  selfhost_times=()
  for ((i=1; i<=RUNS; i++)); do
    start=$(now_us)
    moonrun "$SELFHOST_CHECKER" --check --file "$case_path" >/dev/null 2>&1 || true
    end=$(now_us)
    selfhost_times+=($((end - start)))
  done

  # Median
  moonbit_sorted=($(printf '%s\n' "${moonbit_times[@]}" | sort -n))
  selfhost_sorted=($(printf '%s\n' "${selfhost_times[@]}" | sort -n))
  mid=$((RUNS / 2))
  m_median=${moonbit_sorted[$mid]}
  s_median=${selfhost_sorted[$mid]}

  if [ "$m_median" -gt 0 ]; then
    ratio=$(awk -v s="$s_median" -v m="$m_median" 'BEGIN { printf "%.2f", s/m }')
  else
    ratio="inf"
  fi

  printf "%-50s %12d %12d %8s\n" "$rel_case" "$m_median" "$s_median" "${ratio}x"
done

echo ""
echo "Note: MoonBit wasm-gc uses empty input (ptr=1024,len=0) as baseline."
echo "      Selfhost checker processes actual file content."
echo "      This measures startup + check overhead, not pure check speed."
