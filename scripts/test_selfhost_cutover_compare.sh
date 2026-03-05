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
#   VIBE_CUTOVER_INCLUDE_FAIL_CASES    — 1: run expected-fail parity canaries (default: 1)
#   VIBE_CUTOVER_MODES                 — comma-separated compile modes (default: mvp,no-dce,debug-errors)
#   VIBE_CUTOVER_STAGE_TIMEOUT_SEC     — per-stage timeout (default: 300)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cutover}"
REQUIRE_PARITY="${VIBE_CUTOVER_REQUIRE_PARITY:-1}"
INCLUDE_COMPILER_SIZE="${VIBE_CUTOVER_INCLUDE_COMPILER_SIZE:-1}"
INCLUDE_FAIL_CASES="${VIBE_CUTOVER_INCLUDE_FAIL_CASES:-1}"
CUTOVER_MODES_RAW="${VIBE_CUTOVER_MODES:-mvp,no-dce,debug-errors}"
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
    echo "| File | Mode | Host | Selfhost | Hash Match | Deterministic |"
    echo "|------|------|------|----------|------------|---------------|"
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

compile_mode() {
  local runtime="$1"
  local mode="$2"
  local source_file="$3"
  local output_file="$4"
  local stdout_file="$5"
  local stderr_file="$6"
  local -a mode_flags=()
  case "$mode" in
    mvp) mode_flags=(--wasm) ;;
    no-dce) mode_flags=(--wasm --no-dce) ;;
    debug-errors) mode_flags=(--wasm --debug-errors) ;;
    *)
      echo "cutover gate failed: unknown mode '$mode' (supported: mvp,no-dce,debug-errors)" >&2
      return 2
      ;;
  esac

  if [ "$runtime" = "host" ]; then
    run_with_timeout "$STAGE_TIMEOUT_SEC" "$VIBE_BIN" compile "${mode_flags[@]}" "$source_file" -o "$output_file" >"$stdout_file" 2>"$stderr_file"
    return $?
  fi
  if [ "$runtime" = "selfhost" ]; then
    run_with_timeout "$STAGE_TIMEOUT_SEC" moonrun "$STAGE1_COMPILER_WASM" "${mode_flags[@]}" "$source_file" -o "$output_file" >"$stdout_file" 2>"$stderr_file"
    return $?
  fi

  echo "cutover gate failed: unknown runtime '$runtime'" >&2
  return 2
}

classify_compile_failure() {
  local stdout_file="$1"
  local stderr_file="$2"
  local stdout_text stderr_text
  stdout_text="$(cat "$stdout_file" 2>/dev/null || true)"
  stderr_text="$(cat "$stderr_file" 2>/dev/null || true)"
  if printf '%s\n%s\n' "$stdout_text" "$stderr_text" | rg -q 'compile: parse:|Compile\(Parse|UnexpectedToken'; then
    echo "parse"
    return 0
  fi
  if printf '%s\n%s\n' "$stdout_text" "$stderr_text" | rg -q 'type error:|TypeDiag\(|stage: "type"|type mismatch'; then
    echo "type"
    return 0
  fi
  if printf '%s\n%s\n' "$stdout_text" "$stderr_text" | rg -q 'No such file or directory|not found'; then
    echo "io"
    return 0
  fi
  echo "other"
}

first_output_line() {
  local stdout_file="$1"
  local stderr_file="$2"
  local line
  line="$(awk 'NF { print; exit }' "$stdout_file" 2>/dev/null || true)"
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  awk 'NF { print; exit }' "$stderr_file" 2>/dev/null || true
}

output_contains_fragment() {
  local stdout_file="$1"
  local stderr_file="$2"
  local fragment="$3"
  if [ -z "$fragment" ]; then
    return 0
  fi
  printf '%s\n%s\n' \
    "$(cat "$stdout_file" 2>/dev/null || true)" \
    "$(cat "$stderr_file" 2>/dev/null || true)" | rg -F -q -- "$fragment"
}

declare -a CUTOVER_MODES=()
IFS=',' read -r -a raw_modes <<< "$CUTOVER_MODES_RAW"
for raw_mode in "${raw_modes[@]}"; do
  mode="${raw_mode#"${raw_mode%%[![:space:]]*}"}"
  mode="${mode%"${mode##*[![:space:]]}"}"
  [ -z "$mode" ] && continue
  case "$mode" in
    mvp|no-dce|debug-errors) CUTOVER_MODES+=("$mode") ;;
    *)
      echo "cutover gate failed: unknown VIBE_CUTOVER_MODES item '$mode'" >&2
      exit 1
      ;;
  esac
done
if [ "${#CUTOVER_MODES[@]}" -eq 0 ]; then
  echo "cutover gate failed: VIBE_CUTOVER_MODES must contain at least one mode" >&2
  exit 1
fi
mode_count="${#CUTOVER_MODES[@]}"

total_files=0
total_cases=0
parity_ok=0
parity_fail=0
deterministic_ok=0
deterministic_fail=0
fail_files=0
fail_total_cases=0
fail_parity_ok=0
fail_parity_fail=0

for file in "${CANARY_FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "[cutover] warning: canary file not found, skipping: $file" >&2
    continue
  fi
  total_files=$((total_files + 1))
  basename="$(basename "$file" .vibe)"
  short_file="${file#$PROJECT_ROOT/}"
  for mode in "${CUTOVER_MODES[@]}"; do
    total_cases=$((total_cases + 1))
    mode_suffix="${mode//[^a-zA-Z0-9_-]/_}"
    host_out="$OUT_DIR/${basename}_${mode_suffix}_host.wasm"
    selfhost_out="$OUT_DIR/${basename}_${mode_suffix}_selfhost.wasm"
    selfhost_out2="$OUT_DIR/${basename}_${mode_suffix}_selfhost2.wasm"
    host_stdout="$OUT_DIR/${basename}_${mode_suffix}_host.stdout"
    host_stderr="$OUT_DIR/${basename}_${mode_suffix}_host.stderr"
    selfhost_stdout="$OUT_DIR/${basename}_${mode_suffix}_selfhost.stdout"
    selfhost_stderr="$OUT_DIR/${basename}_${mode_suffix}_selfhost.stderr"
    selfhost_stdout2="$OUT_DIR/${basename}_${mode_suffix}_selfhost2.stdout"
    selfhost_stderr2="$OUT_DIR/${basename}_${mode_suffix}_selfhost2.stderr"

    # Host compile
    set +e
    compile_mode host "$mode" "$file" "$host_out" "$host_stdout" "$host_stderr"
    host_status=$?
    set -e

    # Selfhost compile
    set +e
    compile_mode selfhost "$mode" "$file" "$selfhost_out" "$selfhost_stdout" "$selfhost_stderr"
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
      echo "[cutover] MISMATCH exit code: $file (mode=$mode host=$host_status selfhost=$selfhost_status)" >&2
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
        echo "[cutover] MISMATCH hash: $file (mode=$mode)" >&2
        echo "  host:     $host_hash (${host_size}B)" >&2
        echo "  selfhost: $selfhost_hash (${selfhost_size}B)" >&2
      fi

      # Deterministic check: selfhost compile 2nd time
      set +e
      compile_mode selfhost "$mode" "$file" "$selfhost_out2" "$selfhost_stdout2" "$selfhost_stderr2"
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
          echo "[cutover] NON-DETERMINISTIC: $file (mode=$mode)" >&2
          echo "  run1: $selfhost_hash" >&2
          echo "  run2: $selfhost_hash2" >&2
        fi
      else
        det_label="2nd compile failed"
        deterministic_fail=$((deterministic_fail + 1))
      fi
    fi

    echo "[cutover] $short_file [mode=$mode]: host=$host_label selfhost=$selfhost_label hash=$hash_match det=$det_label"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf -- "| %s | %s | %s | %s | %s | %s |\n" \
        "$short_file" "$mode" "$host_label" "$selfhost_label" "$hash_match" "$det_label" \
        >> "$GITHUB_STEP_SUMMARY" || true
    fi
  done
done

FAIL_CANARY_CASES=()
if [ "$INCLUDE_FAIL_CASES" = "1" ]; then
  FAIL_CANARY_CASES+=(
    "fixtures/typecheck/import_malformed_separator.vibe|parse|UnexpectedToken"
    "fixtures/typecheck/type_mismatch_argument.vibe|type|type mismatch (argument)"
  )
fi

for fail_case in "${FAIL_CANARY_CASES[@]}"; do
  IFS='|' read -r fail_rel_path expected_class expected_fragment <<< "$fail_case"
  fail_file="$PROJECT_ROOT/$fail_rel_path"
  if [ ! -f "$fail_file" ]; then
    echo "[cutover] warning: fail canary not found, skipping: $fail_file" >&2
    continue
  fi
  fail_files=$((fail_files + 1))
  basename="$(basename "$fail_file" .vibe)"
  short_file="${fail_file#$PROJECT_ROOT/}"
  for mode in "${CUTOVER_MODES[@]}"; do
    total_cases=$((total_cases + 1))
    fail_total_cases=$((fail_total_cases + 1))
    mode_suffix="${mode//[^a-zA-Z0-9_-]/_}"
    host_out="$OUT_DIR/${basename}_${mode_suffix}_fail_host.wasm"
    selfhost_out="$OUT_DIR/${basename}_${mode_suffix}_fail_selfhost.wasm"
    host_stdout="$OUT_DIR/${basename}_${mode_suffix}_fail_host.stdout"
    host_stderr="$OUT_DIR/${basename}_${mode_suffix}_fail_host.stderr"
    selfhost_stdout="$OUT_DIR/${basename}_${mode_suffix}_fail_selfhost.stdout"
    selfhost_stderr="$OUT_DIR/${basename}_${mode_suffix}_fail_selfhost.stderr"

    set +e
    compile_mode host "$mode" "$fail_file" "$host_out" "$host_stdout" "$host_stderr"
    host_status=$?
    set -e

    set +e
    compile_mode selfhost "$mode" "$fail_file" "$selfhost_out" "$selfhost_stdout" "$selfhost_stderr"
    selfhost_status=$?
    set -e

    host_class="unknown"
    selfhost_class="unknown"
    hash_match="EXPECTED FAIL"
    det_label="n/a"
    pass_case=1

    if [ "$host_status" -eq 0 ] || [ "$selfhost_status" -eq 0 ]; then
      pass_case=0
      hash_match="UNEXPECTED SUCCESS"
      det_label="n/a"
      echo "[cutover] FAIL-CANARY mismatch: expected both fail: $fail_file (mode=$mode host=$host_status selfhost=$selfhost_status)" >&2
    else
      host_class="$(classify_compile_failure "$host_stdout" "$host_stderr")"
      selfhost_class="$(classify_compile_failure "$selfhost_stdout" "$selfhost_stderr")"
      host_label="exit=$host_status class=$host_class"
      selfhost_label="exit=$selfhost_status class=$selfhost_class"
      det_label="expected=$expected_class"
      if [ "$host_class" != "$selfhost_class" ]; then
        pass_case=0
        hash_match="FAIL CLASS MISMATCH"
        echo "[cutover] FAIL-CANARY class mismatch: $fail_file (mode=$mode host=$host_class selfhost=$selfhost_class)" >&2
      elif [ -n "$expected_class" ] && [ "$host_class" != "$expected_class" ]; then
        pass_case=0
        hash_match="FAIL CLASS UNEXPECTED"
        echo "[cutover] FAIL-CANARY unexpected class: $fail_file (mode=$mode expected=$expected_class actual=$host_class)" >&2
      elif [ -n "$expected_fragment" ] && ! output_contains_fragment "$host_stdout" "$host_stderr" "$expected_fragment"; then
        pass_case=0
        hash_match="FAIL MSG MISSING(host)"
        echo "[cutover] FAIL-CANARY missing expected fragment in host output: $fail_file (mode=$mode fragment='$expected_fragment')" >&2
      elif [ -n "$expected_fragment" ] && ! output_contains_fragment "$selfhost_stdout" "$selfhost_stderr" "$expected_fragment"; then
        pass_case=0
        hash_match="FAIL MSG MISSING(selfhost)"
        echo "[cutover] FAIL-CANARY missing expected fragment in selfhost output: $fail_file (mode=$mode fragment='$expected_fragment')" >&2
      else
        hash_match="YES"
        if [ -n "$expected_fragment" ]; then
          det_label="expected=$expected_class,fragment=$expected_fragment"
        fi
      fi
    fi

    if [ "$pass_case" -eq 1 ]; then
      parity_ok=$((parity_ok + 1))
      fail_parity_ok=$((fail_parity_ok + 1))
      if [ -z "${host_label:-}" ]; then
        host_label="exit=$host_status class=$host_class"
      fi
      if [ -z "${selfhost_label:-}" ]; then
        selfhost_label="exit=$selfhost_status class=$selfhost_class"
      fi
    else
      parity_fail=$((parity_fail + 1))
      fail_parity_fail=$((fail_parity_fail + 1))
      host_label="exit=$host_status class=${host_class}"
      selfhost_label="exit=$selfhost_status class=${selfhost_class}"
      host_first="$(first_output_line "$host_stdout" "$host_stderr")"
      selfhost_first="$(first_output_line "$selfhost_stdout" "$selfhost_stderr")"
      echo "  host first: ${host_first:-<none>}" >&2
      echo "  self first: ${selfhost_first:-<none>}" >&2
    fi

    echo "[cutover] $short_file [mode=$mode fail=$expected_class]: host=$host_label selfhost=$selfhost_label result=$hash_match"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf -- "| %s (fail:%s) | %s | %s | %s | %s | %s |\n" \
        "$short_file" "$expected_class" "$mode" "$host_label" "$selfhost_label" "$hash_match" "$det_label" \
        >> "$GITHUB_STEP_SUMMARY" || true
    fi
  done
done

echo ""
echo "[cutover] summary: success=${total_files} files + fail=${fail_files} files, modes=${mode_count}, total=${total_cases} cases, parity-ok=${parity_ok}, parity-fail=${parity_fail}, deterministic-ok=${deterministic_ok}, deterministic-fail=${deterministic_fail}, failcase-ok=${fail_parity_ok}, failcase-fail=${fail_parity_fail}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "**Summary**: success=${total_files} files + fail=${fail_files} files, modes=${mode_count}, total=${total_cases} cases, parity-ok=${parity_ok}, parity-fail=${parity_fail}, deterministic-ok=${deterministic_ok}, deterministic-fail=${deterministic_fail}, failcase-ok=${fail_parity_ok}, failcase-fail=${fail_parity_fail}"
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
