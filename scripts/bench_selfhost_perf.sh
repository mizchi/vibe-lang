#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

SELFHOST_WASM_PROFILE="${VIBE_SELFHOST_PERF_WASM_PROFILE:-debug}"
DEFAULT_STAGE1_COMPILER_WASM="$PROJECT_ROOT/_build/wasm/$SELFHOST_WASM_PROFILE/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
DEFAULT_STAGE1_CHECKER_WASM="$PROJECT_ROOT/_build/wasm/$SELFHOST_WASM_PROFILE/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$DEFAULT_STAGE1_COMPILER_WASM}"
STAGE1_CHECKER_WASM="${STAGE1_CHECKER_WASM:-$DEFAULT_STAGE1_CHECKER_WASM}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_perf}"
CASES_FILE="${VIBE_SELFHOST_PERF_CASES_FILE:-$PROJECT_ROOT/bench/selfhost_perf/cases.txt}"
RUNS="${VIBE_SELFHOST_PERF_RUNS:-3}"
COMPILE_MODE="${VIBE_SELFHOST_PERF_COMPILE_MODE:-e2e}"
MAX_COMPILE_RATIO="${VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO:-}"
MAX_CHECK_RATIO="${VIBE_SELFHOST_PERF_MAX_CHECK_RATIO:-}"
REBUILD_MODE="${VIBE_SELFHOST_PERF_REBUILD:-auto}"
PROFILE_CALLSTACK="${VIBE_SELFHOST_PERF_PROFILE_CALLSTACK:-}"

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

ensure_binaries() {
  if [ "$SELFHOST_WASM_PROFILE" != "release" ] && [ "$SELFHOST_WASM_PROFILE" != "debug" ]; then
    echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_WASM_PROFILE must be release or debug" >&2
    exit 1
  fi
  if [ "$REBUILD_MODE" != "auto" ] && [ "$REBUILD_MODE" != "always" ] && [ "$REBUILD_MODE" != "never" ]; then
    echo "bench-selfhost-perf: VIBE_SELFHOST_PERF_REBUILD must be auto|always|never" >&2
    exit 1
  fi
  local src_changed_since_host=0
  local src_changed_since_compiler=0
  local src_changed_since_checker=0
  if [ "$REBUILD_MODE" = "always" ]; then
    src_changed_since_host=1
    src_changed_since_compiler=1
    src_changed_since_checker=1
  elif [ "$REBUILD_MODE" = "auto" ]; then
    if [ ! -x "$VIBE_BIN" ] || [ -n "$(find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' -o -name 'moon.mod.json' \) -newer "$VIBE_BIN" -print -quit 2>/dev/null)" ]; then
      src_changed_since_host=1
    fi
    if [ ! -f "$STAGE1_COMPILER_WASM" ] || [ -n "$(find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' -o -name 'moon.mod.json' \) -newer "$STAGE1_COMPILER_WASM" -print -quit 2>/dev/null)" ]; then
      src_changed_since_compiler=1
    fi
    if [ ! -f "$STAGE1_CHECKER_WASM" ] || [ -n "$(find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' -o -name 'moon.mod.json' \) -newer "$STAGE1_CHECKER_WASM" -print -quit 2>/dev/null)" ]; then
      src_changed_since_checker=1
    fi
  fi

  if [ ! -x "$VIBE_BIN" ] || [ "$src_changed_since_host" -eq 1 ]; then
    echo "[selfhost-perf] building host CLI..."
    moon build --target native --release src/cmd/vibe --warn-list '-29'
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
  if ! command -v moonrun >/dev/null 2>&1; then
    echo "bench-selfhost-perf: moonrun not found" >&2
    exit 1
  fi
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

  local case_path rel_case safe
  for case_path in "${cases[@]}"; do
    rel_case="${case_path#$PROJECT_ROOT/}"
    safe="$(echo "$rel_case" | tr '/: ' '___')"
    for phase in compile check; do
      for runtime in host selfhost; do
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
          if [ -n "$PROFILE_CALLSTACK" ] && [ "$phase" = "compile" ] && [ "$run_idx" -eq 1 ]; then
            local callstack_file="$OUT_DIR/tmp/${safe}.${phase}.${runtime}.callstack.tsv"
            callstack_args=(--profile-callstack "$callstack_file")
          fi
          local cmd_status elapsed
          if [ "$phase" = "compile" ] && [ "$runtime" = "host" ] && [ "$COMPILE_MODE" = "e2e" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              "$VIBE_BIN" compile-lite --wasm --no-dce --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path" -o "$OUT_DIR/tmp/${safe}.${run_idx}.host.wasm")
          elif [ "$phase" = "compile" ] && [ "$runtime" = "selfhost" ] && [ "$COMPILE_MODE" = "e2e" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              moonrun "$STAGE1_COMPILER_WASM" compile-lite --wasm --no-dce --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path" -o "$OUT_DIR/tmp/${safe}.${run_idx}.selfhost.wasm")
          elif [ "$phase" = "compile" ] && [ "$runtime" = "host" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              "$VIBE_BIN" compile-lite --wasm --no-dce --in-memory --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path")
          elif [ "$phase" = "compile" ] && [ "$runtime" = "selfhost" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              moonrun "$STAGE1_COMPILER_WASM" compile-lite --wasm --no-dce --in-memory --profile-tsv "$profile_file" "${callstack_args[@]+"${callstack_args[@]}"}" "$case_path")
          elif [ "$phase" = "check" ] && [ "$runtime" = "host" ]; then
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              env VIBE_CHECK_DEBUG=0 "$VIBE_BIN" check --profile-tsv "$profile_file" "$case_path")
          else
            read -r cmd_status elapsed < <(run_timed "$stdout_file" "$stderr_file" \
              moonrun "$STAGE1_CHECKER_WASM" --check --profile-tsv "$profile_file" --file "$case_path")
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

    if [ -n "$MAX_COMPILE_RATIO" ] && ratio_exceeds "$cratio" "$MAX_COMPILE_RATIO"; then
      echo "bench-selfhost-perf: compile ratio exceeded ($rel_case: $cratio > $MAX_COMPILE_RATIO)" >&2
      fail_ratio=1
    fi
    if [ -n "$MAX_CHECK_RATIO" ] && ratio_exceeds "$kratio" "$MAX_CHECK_RATIO"; then
      echo "bench-selfhost-perf: check ratio exceeded ($rel_case: $kratio > $MAX_CHECK_RATIO)" >&2
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

  echo
  echo "=== selfhost perf summary (median ms) ==="
  column -t -s $'\t' "$summary_tsv"
  echo
  echo "TOTAL compile(host/selfhost): ${sum_compile_host} / ${sum_compile_self} ms (ratio=${total_compile_ratio})"
  echo "TOTAL check(host/selfhost):   ${sum_check_host} / ${sum_check_self} ms (ratio=${total_check_ratio})"
  echo "raw:     $raw_tsv"
  echo "summary: $summary_tsv"
  if [ -s "$stage_summary_tsv" ]; then
    echo "stage summary:"
    column -t -s $'\t' "$stage_summary_tsv"
    echo
    echo "top selfhost hotspots:"
    {
      printf "file\tphase\tstage\tselfhost_us\tratio\n"
      tail -n +2 "$stage_summary_tsv" | sort -t $'\t' -k5,5nr | head -n 8 | awk -F'\t' '{ printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $5, $6 }'
    } | column -t -s $'\t'
    echo
    echo "worst selfhost ratios:"
    {
      printf "file\tphase\tstage\thost_us\tselfhost_us\tratio\n"
      tail -n +2 "$stage_summary_tsv" | sort -t $'\t' -k6,6nr | head -n 8
    } | column -t -s $'\t'
    echo "raw stage:     $raw_stage_tsv"
    echo "stage summary: $stage_summary_tsv"
  fi

  if [ -n "$MAX_COMPILE_RATIO" ] && ratio_exceeds "$total_compile_ratio" "$MAX_COMPILE_RATIO"; then
    echo "bench-selfhost-perf: total compile ratio exceeded (${total_compile_ratio} > ${MAX_COMPILE_RATIO})" >&2
    fail_ratio=1
  fi
  if [ -n "$MAX_CHECK_RATIO" ] && ratio_exceeds "$total_check_ratio" "$MAX_CHECK_RATIO"; then
    echo "bench-selfhost-perf: total check ratio exceeded (${total_check_ratio} > ${MAX_CHECK_RATIO})" >&2
    fail_ratio=1
  fi

  if [ "$fail_ratio" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
