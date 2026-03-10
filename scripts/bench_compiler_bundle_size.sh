#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
REPORT_DIR="$ROOT_DIR/dist/bundle_size"
REPORT_FILE="$REPORT_DIR/compiler_current.tsv"
BUDGET_FILE="$ROOT_DIR/bench/golden/compiler_bundle_size_budget.tsv"
CASES_FILE="$ROOT_DIR/bench/compiler_size/cases.txt"
OUT_DIR="$REPORT_DIR/out_compiler"
UPDATE=0

if [[ "${1:-}" == "--update" ]]; then
  UPDATE=1
  shift
fi

if [[ $# -ne 0 ]]; then
  echo "usage: $0 [--update]" >&2
  exit 2
fi

mkdir -p "$REPORT_DIR" "$OUT_DIR"

moon build --target native --release src/cmd/vibe >/dev/null

printf 'group\tpath\tmode\tbytes\n' > "$REPORT_FILE"

declare -a active_groups
active_groups=()

add_active_group() {
  local group="$1"
  for active in "${active_groups[@]}"; do
    if [[ "$active" == "$group" ]]; then
      return 0
    fi
  done
  active_groups+=("$group")
}

try_compile() {
  local exit_code=0
  local _discard=""
  _discard="$("$CLI_BIN" compile "$@" 2>&1)" || exit_code=$?
  [[ $exit_code -eq 0 ]]
}

compile_entry() {
  local group="$1"
  local path="$2"
  local prefer_no_dce="${3:-1}"
  local out_key
  local out_path
  local mode
  local bytes
  local group_key

  group_key="$(echo "$group" | tr '/.' '__')"
  out_key="${group_key}_$(echo "$path" | tr '/.' '__')"
  out_path="$OUT_DIR/$out_key.wasm"

  if [[ "$prefer_no_dce" == "1" ]]; then
    if try_compile --wasm --no-dce "$path" -o "$out_path"; then
      mode="wasm-no-dce"
    elif try_compile --wasm-js-string --no-dce "$path" -o "$out_path"; then
      mode="wasm-js-string-no-dce"
    elif try_compile --wasm "$path" -o "$out_path"; then
      mode="wasm"
    elif try_compile --wasm-js-string "$path" -o "$out_path"; then
      mode="wasm-js-string"
    else
      mode="unsupported"
      bytes="-1"
      printf '%s\t%s\t%s\t%s\n' "$group" "$path" "$mode" "$bytes" >> "$REPORT_FILE"
      return 0
    fi
  else
    if try_compile --wasm "$path" -o "$out_path"; then
      mode="wasm"
    elif try_compile --wasm-js-string "$path" -o "$out_path"; then
      mode="wasm-js-string"
    elif try_compile --wasm --no-dce "$path" -o "$out_path"; then
      mode="wasm-no-dce"
    elif try_compile --wasm-js-string --no-dce "$path" -o "$out_path"; then
      mode="wasm-js-string-no-dce"
    else
      mode="unsupported"
      bytes="-1"
      printf '%s\t%s\t%s\t%s\n' "$group" "$path" "$mode" "$bytes" >> "$REPORT_FILE"
      return 0
    fi
  fi

  bytes="$(wc -c < "$out_path" | tr -d '[:space:]')"
  printf '%s\t%s\t%s\t%s\n' "$group" "$path" "$mode" "$bytes" >> "$REPORT_FILE"
}

if [[ ! -f "$CASES_FILE" ]]; then
  echo "compiler-bundle-size: missing case list: $CASES_FILE" >&2
  exit 1
fi

while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  set -- $line
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "compiler-bundle-size: invalid case line (expected: <group> <path> [prefer_no_dce]): $line" >&2
    exit 1
  fi

  group="$1"
  rel_path="$2"
  prefer_no_dce="${3:-1}"

  case "$prefer_no_dce" in
    0|1)
      ;;
    *)
      echo "compiler-bundle-size: invalid prefer_no_dce (expected 0 or 1): $line" >&2
      exit 1
      ;;
  esac

  abs_path="$ROOT_DIR/$rel_path"
  if [[ ! -f "$abs_path" ]]; then
    echo "compiler-bundle-size: case missing file: $rel_path" >&2
    exit 1
  fi

  add_active_group "$group"
  compile_entry "$group" "$rel_path" "$prefer_no_dce"
done < "$CASES_FILE"

{
  head -n 1 "$REPORT_FILE"
  tail -n +2 "$REPORT_FILE" | sort
} > "$REPORT_FILE.sorted"
mv "$REPORT_FILE.sorted" "$REPORT_FILE"

echo "compiler-bundle-size: wrote $REPORT_FILE"

echo ""
echo "[totals]"
awk -F '\t' 'NR > 1 { sum[$1] += $4 } END { for (g in sum) { printf "%s\t%d\n", g, sum[g] } }' \
  "$REPORT_FILE" | sort

echo ""
echo "[top 10 largest]"
tail -n +2 "$REPORT_FILE" | sort -t $'\t' -k4,4nr | head -n 10 | \
  awk -F '\t' '{ printf "%-14s %-48s %-15s %7d\n", $1, $2, $3, $4 }'

echo ""
echo "[unsupported]"
awk -F '\t' 'NR > 1 && $3 == "unsupported" { printf "%s\t%s\n", $1, $2 }' "$REPORT_FILE"

if [[ $UPDATE -eq 1 ]]; then
  mkdir -p "$(dirname "$BUDGET_FILE")"
  cp "$REPORT_FILE" "$BUDGET_FILE"
  echo ""
  echo "compiler-bundle-size: updated budget file: $BUDGET_FILE"
  exit 0
fi

if [[ ! -f "$BUDGET_FILE" ]]; then
  echo ""
  echo "compiler-bundle-size: missing budget file: $BUDGET_FILE" >&2
  echo "run: scripts/bench_compiler_bundle_size.sh --update" >&2
  exit 1
fi

declare -A budget_mode
declare -A budget_bytes
declare -A seen_keys

while IFS=$'\t' read -r group path mode bytes; do
  if [[ "$group" == "group" ]]; then
    continue
  fi
  key="$group|$path"
  budget_mode["$key"]="$mode"
  budget_bytes["$key"]="$bytes"
done < "$BUDGET_FILE"

status=0

while IFS=$'\t' read -r group path mode bytes; do
  if [[ "$group" == "group" ]]; then
    continue
  fi
  key="$group|$path"
  seen_keys["$key"]="1"
  if [[ -z "${budget_bytes[$key]+x}" ]]; then
    echo "compiler-bundle-size: new entry without budget: $group $path ($mode $bytes)" >&2
    status=1
    continue
  fi
  expected_mode="${budget_mode[$key]}"
  expected_bytes="${budget_bytes[$key]}"
  if [[ "$mode" != "$expected_mode" ]]; then
    echo "compiler-bundle-size: mode changed: $group $path (got=$mode expected=$expected_mode)" >&2
    status=1
  fi
  if [[ "$mode" == "unsupported" ]]; then
    continue
  fi
  if (( bytes > expected_bytes )); then
    echo "compiler-bundle-size: size regression: $group $path (got=$bytes budget=$expected_bytes)" >&2
    status=1
  fi
done < "$REPORT_FILE"

is_active_group() {
  local group="$1"
  for active in "${active_groups[@]}"; do
    if [[ "$active" == "$group" ]]; then
      return 0
    fi
  done
  return 1
}

for key in "${!budget_bytes[@]}"; do
  group="${key%%|*}"
  if ! is_active_group "$group"; then
    continue
  fi
  if [[ -z "${seen_keys[$key]+x}" ]]; then
    echo "compiler-bundle-size: stale budget entry: $key" >&2
    status=1
  fi
done

if (( status != 0 )); then
  exit 1
fi

echo ""
echo "compiler-bundle-size: all entries are within budget."
