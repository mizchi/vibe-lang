#!/usr/bin/env bash
set -euo pipefail

# WASM Codegen 比較分析スクリプト
# MoonBit wasm-gc と Selfhost MVP の命令パターンを比較する

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

MOONBIT_GC="${MOONBIT_GC:-$PROJECT_ROOT/_build/wasm-gc/release/build/lib/lib.wasm}"
SELFHOST_MVP="${SELFHOST_MVP:-$PROJECT_ROOT/_build/wasm/release/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools not found" >&2
  exit 1
fi

# Build if needed
if [ ! -f "$MOONBIT_GC" ]; then
  echo "[build] MoonBit wasm-gc release..."
  (cd "$PROJECT_ROOT" && moon build --target wasm-gc --release src/lib)
fi
if [ ! -f "$SELFHOST_MVP" ]; then
  echo "[build] Selfhost WASM release..."
  (cd "$PROJECT_ROOT" && moon build --target wasm --release src/cmd/vibe_compile_wasi)
fi

echo "=== Binary Info ==="
printf "%-20s %s\n" "MoonBit wasm-gc:" "$(wc -c < "$MOONBIT_GC" | tr -d ' ') bytes"
printf "%-20s %s\n" "Selfhost MVP:" "$(wc -c < "$SELFHOST_MVP" | tr -d ' ') bytes"
echo ""

echo "=== Section Comparison ==="
echo "--- MoonBit wasm-gc ---"
wasm-tools objdump "$MOONBIT_GC"
echo ""
echo "--- Selfhost MVP ---"
wasm-tools objdump "$SELFHOST_MVP"
echo ""

count_pat() {
  local file="$1" pat="$2"
  wasm-tools print "$file" 2>/dev/null | grep -cE "$pat" || echo 0
}

echo "=== Instruction Frequency ==="
printf "%-25s %12s %12s %8s\n" "Instruction" "MoonBit-GC" "Selfhost" "Ratio"
printf "%-25s %12s %12s %8s\n" "---------" "----------" "--------" "-----"

patterns=(
  "call_indirect"
  "call "
  "call_ref"
  "local\.get"
  "local\.set"
  "local\.tee"
  "global\.get"
  "global\.set"
  "i32\.const"
  "i32\.load "
  "i32\.store "
  "i32\.load8"
  "i32\.store8"
  "struct\.new"
  "struct\.get"
  "struct\.set"
  "array\.new"
  "array\.get"
  "array\.set"
  "array\.copy"
  "ref\.cast"
  "ref\.func"
  "if "
  "block"
  "loop"
  "br "
  "br_table"
  "i32\.add"
  "i32\.sub"
  "i32\.shl"
  "i32\.and"
  "i32\.or"
  "i64\.extend_i32"
  "i32\.wrap_i64"
  "drop"
  "unreachable"
  "memory\.copy"
  "memory\.grow"
)

for pat in "${patterns[@]}"; do
  m=$(count_pat "$MOONBIT_GC" "$pat")
  s=$(count_pat "$SELFHOST_MVP" "$pat")
  if [ "$m" -gt 0 ]; then
    ratio=$(awk -v s="$s" -v m="$m" 'BEGIN { printf "%.1fx", s/m }')
  elif [ "$s" -gt 0 ]; then
    ratio="inf"
  else
    ratio="-"
  fi
  printf "%-25s %12d %12d %8s\n" "$pat" "$m" "$s" "$ratio"
done

echo ""
echo "=== Summary ==="
m_total=$(wasm-tools print "$MOONBIT_GC" 2>/dev/null | grep -cvE '^\s*(\(|\)|$)' || echo 0)
s_total=$(wasm-tools print "$SELFHOST_MVP" 2>/dev/null | grep -cvE '^\s*(\(|\)|$)' || echo 0)
printf "Total instructions: MoonBit=%d  Selfhost=%d  Ratio=%.1fx\n" "$m_total" "$s_total" "$(awk -v s="$s_total" -v m="$m_total" 'BEGIN { printf "%.1f", s/m }')"
