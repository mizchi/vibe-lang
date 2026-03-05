#!/usr/bin/env bash
set -euo pipefail

# Selfhost cutover comparison: host vs selfhost wasm output parity.
# Compiles canary files with both host CLI and selfhost WASI compiler,
# then compares exit codes, wasm byte hashes, and deterministic output.
#
# Env:
#   VIBE_BIN                           — host CLI binary (default: auto-detect)
#   STAGE1_COMPILER_WASM               — selfhost WASI compiler wasm
#   VIBE_CUTOVER_REQUIRE_PARITY        — 1: fail on mismatch (default: 1), 0: monitor-only
#   VIBE_CUTOVER_INCLUDE_COMPILER_SIZE — 1: add bench/compiler_size/cases.txt canaries (default: 1)
#   VIBE_CUTOVER_STAGE_TIMEOUT_SEC     — per-stage timeout (default: 300)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cutover}"
REQUIRE_PARITY="${VIBE_CUTOVER_REQUIRE_PARITY:-1}"
INCLUDE_COMPILER_SIZE="${VIBE_CUTOVER_INCLUDE_COMPILER_SIZE:-1}"
STAGE_TIMEOUT_SEC="${VIBE_CUTOVER_STAGE_TIMEOUT_SEC:-300}"

run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ "$timeout_sec" -le 0 ]; then
    "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" "$@"
    return $?
  fi
  "$@" &
  local cmd_pid=$!
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!
  wait "$cmd_pid"
  local status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [ "$status" -eq 143 ] || [ "$status" -eq 137 ]; then
    return 124
  fi
  return "$status"
}

mkdir -p "$OUT_DIR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost Cutover Comparison"
    echo
    echo "| File | Host | Selfhost | Hash Match | Deterministic |"
    echo "|------|------|----------|------------|---------------|"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

# Canary set
CANARY_FILES=(
  "$PROJECT_ROOT/examples/basics.vibe"
  "$PROJECT_ROOT/vibe/compiler/index.vibe"
)

# Expand to compiler_size cases if requested
if [ "$INCLUDE_COMPILER_SIZE" = "1" ] && [ -f "$PROJECT_ROOT/bench/compiler_size/cases.txt" ]; then
  while IFS= read -r case_line; do
    # Skip blanks/comments and parse "<group> <path> <prefer_no_dce>" rows.
    case_line="${case_line#"${case_line%%[![:space:]]*}"}"
    [ -z "$case_line" ] && continue
    [[ "$case_line" == \#* ]] && continue
    IFS=' ' read -r _group path _prefer_no_dce _rest <<< "$case_line"
    [ -z "${path:-}" ] && continue
    CANARY_FILES+=("$PROJECT_ROOT/$path")
  done < "$PROJECT_ROOT/bench/compiler_size/cases.txt"
fi

# Verify prerequisites
if [ ! -x "$VIBE_BIN" ]; then
  echo "[cutover] host CLI not found: $VIBE_BIN" >&2
  echo "[cutover] building host CLI..." >&2
  moon build --target native --release src/cmd/vibe --warn-list '-29'
fi

needs_selfhost_build=0
if [ ! -f "$STAGE1_COMPILER_WASM" ]; then
  needs_selfhost_build=1
fi
if [ "$needs_selfhost_build" -eq 1 ]; then
  echo "[cutover] selfhost WASI compiler not found: $STAGE1_COMPILER_WASM" >&2
  echo "[cutover] building selfhost WASI compiler..." >&2
  moon build --target wasm src/cmd/vibe_compile_wasi
fi

if ! command -v moonrun >/dev/null 2>&1; then
  echo "cutover gate failed: moonrun not found" >&2
  exit 1
fi

total_files=0
parity_ok=0
parity_fail=0
deterministic_ok=0
deterministic_fail=0

for file in "${CANARY_FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "[cutover] warning: canary file not found, skipping: $file" >&2
    continue
  fi
  total_files=$((total_files + 1))
  basename="$(basename "$file" .vibe)"
  host_out="$OUT_DIR/${basename}_host.wasm"
  selfhost_out="$OUT_DIR/${basename}_selfhost.wasm"
  selfhost_out2="$OUT_DIR/${basename}_selfhost2.wasm"

  # Host compile
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$VIBE_BIN" compile --wasm "$file" -o "$host_out" >/dev/null 2>&1
  host_status=$?
  set -e

  # Selfhost compile
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" moonrun "$STAGE1_COMPILER_WASM" --wasm "$file" -o "$selfhost_out" >/dev/null 2>&1
  selfhost_status=$?
  set -e

  # Compare exit codes
  host_label="exit=$host_status"
  selfhost_label="exit=$selfhost_status"

  if [ "$host_status" -ne 0 ] && [ "$selfhost_status" -ne 0 ]; then
    # Both failed — that's parity (both reject)
    hash_match="n/a (both fail)"
    parity_ok=$((parity_ok + 1))
    det_label="n/a"
  elif [ "$host_status" -ne "$selfhost_status" ]; then
    # One succeeded, one failed — mismatch
    hash_match="EXIT MISMATCH"
    parity_fail=$((parity_fail + 1))
    det_label="n/a"
    echo "[cutover] MISMATCH exit code: $file (host=$host_status selfhost=$selfhost_status)" >&2
  else
    # Both succeeded — compare hashes
    host_hash="$(shasum -a 256 "$host_out" | awk '{print $1}')"
    selfhost_hash="$(shasum -a 256 "$selfhost_out" | awk '{print $1}')"
    host_size="$(wc -c < "$host_out" | tr -d ' ')"
    selfhost_size="$(wc -c < "$selfhost_out" | tr -d ' ')"
    host_label="exit=0 ${host_size}B"
    selfhost_label="exit=0 ${selfhost_size}B"

    if [ "$host_hash" = "$selfhost_hash" ]; then
      hash_match="YES"
      parity_ok=$((parity_ok + 1))
    else
      hash_match="NO (host=${host_hash:0:12}... selfhost=${selfhost_hash:0:12}...)"
      parity_fail=$((parity_fail + 1))
      echo "[cutover] MISMATCH hash: $file" >&2
      echo "  host:     $host_hash (${host_size}B)" >&2
      echo "  selfhost: $selfhost_hash (${selfhost_size}B)" >&2
    fi

    # Deterministic check: selfhost compile 2nd time
    set +e
    run_with_timeout "$STAGE_TIMEOUT_SEC" moonrun "$STAGE1_COMPILER_WASM" --wasm "$file" -o "$selfhost_out2" >/dev/null 2>&1
    selfhost_status2=$?
    set -e
    if [ "$selfhost_status2" -eq 0 ]; then
      selfhost_hash2="$(shasum -a 256 "$selfhost_out2" | awk '{print $1}')"
      if [ "$selfhost_hash" = "$selfhost_hash2" ]; then
        det_label="YES"
        deterministic_ok=$((deterministic_ok + 1))
      else
        det_label="NO"
        deterministic_fail=$((deterministic_fail + 1))
        echo "[cutover] NON-DETERMINISTIC: $file" >&2
        echo "  run1: $selfhost_hash" >&2
        echo "  run2: $selfhost_hash2" >&2
      fi
    else
      det_label="2nd compile failed"
      deterministic_fail=$((deterministic_fail + 1))
    fi
  fi

  short_file="${file#$PROJECT_ROOT/}"
  echo "[cutover] $short_file: host=$host_label selfhost=$selfhost_label hash=$hash_match det=$det_label"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "| %s | %s | %s | %s | %s |\n" \
      "$short_file" "$host_label" "$selfhost_label" "$hash_match" "$det_label" \
      >> "$GITHUB_STEP_SUMMARY" || true
  fi
done

echo ""
echo "[cutover] summary: ${total_files} files, ${parity_ok} parity-ok, ${parity_fail} parity-fail, ${deterministic_ok} deterministic-ok, ${deterministic_fail} deterministic-fail"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "**Summary**: ${total_files} files, ${parity_ok} parity-ok, ${parity_fail} parity-fail, ${deterministic_ok} det-ok, ${deterministic_fail} det-fail"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ "$REQUIRE_PARITY" = "1" ] && [ "$parity_fail" -gt 0 ]; then
  echo "cutover gate failed: ${parity_fail} file(s) with hash mismatch" >&2
  exit 1
fi

if [ "$deterministic_fail" -gt 0 ]; then
  echo "cutover gate failed: ${deterministic_fail} file(s) non-deterministic" >&2
  exit 1
fi

echo "cutover compare passed"
