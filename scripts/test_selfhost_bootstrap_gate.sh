#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_bootstrap}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
KPI_BASELINE_SEC="${VIBE_SELFHOST_BOOTSTRAP_BASELINE_SEC:-}"
KPI_REDUCTION_PCT="${VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT:-30}"
PIPELINE_OPT_LEVEL="${VIBE_SELFHOST_PIPELINE_OPT_LEVEL:-}"
SELFHOST_TEST_JOBS="${VIBE_SELFHOST_BOOTSTRAP_TEST_JOBS:-}"

run_stage() {
  local name="$1"
  shift
  local start end elapsed
  start="$(date +%s)"
  echo "[bootstrap] $name"
  "$@"
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[bootstrap] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

run_stage_capture_stdout() {
  local name="$1"
  local out_path="$2"
  shift 2
  local start end elapsed
  start="$(date +%s)"
  echo "[bootstrap] $name"
  "$@" >"$out_path"
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[bootstrap] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_positive_int() {
  if ! is_non_negative_int "$1"; then
    return 1
  fi
  [ "$1" -gt 0 ]
}

detect_default_test_jobs() {
  local cpus
  cpus=""
  if command -v nproc >/dev/null 2>&1; then
    cpus="$(nproc || true)"
  elif command -v sysctl >/dev/null 2>&1; then
    cpus="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if ! is_positive_int "${cpus:-}"; then
    cpus=4
  fi
  if [ "$cpus" -gt 8 ]; then
    cpus=8
  fi
  echo "$cpus"
}

run_wasm_and_expect_zero() {
  local label="$1"
  local wasm_path="$2"
  local out_path="$3"
  local start end elapsed run_value
  start="$(date +%s)"
  echo "[bootstrap] $label"
  env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
    "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$wasm_path" >"$out_path"
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[bootstrap] done: $label (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$label" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  run_value="$(rg -v '^warning' "$out_path" | tail -n 1)"
  if ! [[ "$run_value" =~ ^-?[0-9]+$ ]]; then
    echo "bootstrap gate failed: $label did not return numeric value: $run_value" >&2
    exit 1
  fi
  if [ "$run_value" != "0" ]; then
    echo "bootstrap gate failed: expected $label return 0, got $run_value" >&2
    exit 1
  fi
}

bootstrap_total_start="$(date +%s)"

needs_cli_rebuild=0
if [ ! -x "$VIBE_BIN" ]; then
  needs_cli_rebuild=1
elif [ "$PROJECT_ROOT/moon.mod.json" -nt "$VIBE_BIN" ]; then
  needs_cli_rebuild=1
elif find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$VIBE_BIN" -print -quit | grep -q .; then
  needs_cli_rebuild=1
fi

if [ "$needs_cli_rebuild" -eq 1 ]; then
  run_stage "building vibe CLI (native release)" \
    moon build --target native --release src/cmd/vibe --warn-list '-29'
fi

mkdir -p "$OUT_DIR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost Bootstrap Gate Timings"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ -z "$SELFHOST_TEST_JOBS" ]; then
  SELFHOST_TEST_JOBS="$(detect_default_test_jobs)"
fi
if ! is_positive_int "$SELFHOST_TEST_JOBS"; then
  echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_TEST_JOBS must be positive integer" >&2
  exit 1
fi
if [ "$SELFHOST_TEST_JOBS" -gt 16 ]; then
  SELFHOST_TEST_JOBS=16
fi
echo "[bootstrap] selfhost test jobs: $SELFHOST_TEST_JOBS"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %s\n" "selfhost test jobs" "$SELFHOST_TEST_JOBS" >> "$GITHUB_STEP_SUMMARY" || true
fi

run_stage "compiled selfhost test suite" \
  env VIBE_TEST_BACKEND=compiled VIBE_TEST_JOBS="$SELFHOST_TEST_JOBS" \
  "$VIBE_BIN" test --jobs "$SELFHOST_TEST_JOBS" "$PROJECT_ROOT"/vibe/compiler/*_test.vibe

echo "[bootstrap] selfhost __to_string source path check"
if rg -n "double_to_string_compiler" \
  "$PROJECT_ROOT/vibe/compiler/values.vibe" \
  "$PROJECT_ROOT/vibe/compiler/token.vibe" \
  "$PROJECT_ROOT/vibe/compiler/printer.vibe" >/dev/null; then
  echo "bootstrap gate failed: selfhost compiler still depends on double_to_string_compiler" >&2
  exit 1
fi

TOSTRING_PROBE="$OUT_DIR/selfhost_tostring_probe.vibe"
cat >"$TOSTRING_PROBE" <<'EOF'
test "__to_string number parity" {
  assert(string_equals(__to_string(1.5), "1.5"))
  assert(string_equals(__to_string(2.0), "2"))
  assert(string_equals(__to_string(1.5f), "1.5"))
}
EOF
run_stage "compiled __to_string(Double/Float) probe" \
  env VIBE_TEST_BACKEND=compiled "$VIBE_BIN" test "$TOSTRING_PROBE"

run_stage "selfhost probe smoke (vibe integration test index 44)" \
  moon test -p tests -f vibe_integration_test.mbt --target js --warn-list '-29' --index 44

STAGE1_WASM="$OUT_DIR/index_stage1.wasm"
STAGE2_WASM="$OUT_DIR/index_stage2.wasm"
run_stage "stage1 compile (--wasm) for $ENTRY_PATH" \
  "$VIBE_BIN" compile --wasm "$ENTRY_PATH" -o "$STAGE1_WASM"
run_stage "stage2 compile (--wasm) for $ENTRY_PATH" \
  "$VIBE_BIN" compile --wasm "$ENTRY_PATH" -o "$STAGE2_WASM"

PIPELINE_CHECK="$OUT_DIR/index_pipeline_check.log"
PIPELINE_RAW_WASM="$OUT_DIR/index_pipeline_raw.wasm"
PIPELINE_OPT_WASM="$OUT_DIR/index_pipeline_opt.wasm"
run_stage_capture_stdout "pipeline parse+type check for $ENTRY_PATH" \
  "$PIPELINE_CHECK" \
  "$VIBE_BIN" check "$ENTRY_PATH"
run_stage "pipeline codegen (--wasm --no-dce) for $ENTRY_PATH" \
  "$VIBE_BIN" compile --wasm --no-dce "$ENTRY_PATH" -o "$PIPELINE_RAW_WASM"
if [ -n "$PIPELINE_OPT_LEVEL" ]; then
  run_stage "pipeline optimize/codegen (-O$PIPELINE_OPT_LEVEL) for $ENTRY_PATH" \
    "$VIBE_BIN" compile --wasm "-O$PIPELINE_OPT_LEVEL" "$ENTRY_PATH" -o "$PIPELINE_OPT_WASM"
else
  echo "[bootstrap] pipeline optimize/codegen: skipped (set VIBE_SELFHOST_PIPELINE_OPT_LEVEL)"
fi

if command -v wasm-tools >/dev/null 2>&1; then
  run_stage "validate stage1 wasm" wasm-tools validate --features all "$STAGE1_WASM"
  run_stage "validate stage2 wasm" wasm-tools validate --features all "$STAGE2_WASM"
  run_stage "validate pipeline raw wasm" wasm-tools validate --features all "$PIPELINE_RAW_WASM"
  if [ -n "$PIPELINE_OPT_LEVEL" ]; then
    run_stage "validate pipeline opt wasm" wasm-tools validate --features all "$PIPELINE_OPT_WASM"
  fi
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

HASH_STAGE1="$(shasum -a 256 "$STAGE1_WASM" | awk '{print $1}')"
HASH_STAGE2="$(shasum -a 256 "$STAGE2_WASM" | awk '{print $1}')"
if [ "$HASH_STAGE1" != "$HASH_STAGE2" ]; then
  echo "bootstrap gate failed: stage1/stage2 wasm hash mismatch" >&2
  echo "  stage1: $HASH_STAGE1" >&2
  echo "  stage2: $HASH_STAGE2" >&2
  exit 1
fi

run_wasm_and_expect_zero \
  "run stage1 wasm via wasmtime (--invoke run)" \
  "$STAGE1_WASM" \
  "$OUT_DIR/stage1_run.out"
run_wasm_and_expect_zero \
  "run stage2 wasm via wasmtime (--invoke run)" \
  "$STAGE2_WASM" \
  "$OUT_DIR/stage2_run.out"

bootstrap_total_end="$(date +%s)"
bootstrap_total_elapsed="$((bootstrap_total_end - bootstrap_total_start))"
echo "[bootstrap] total elapsed: ${bootstrap_total_elapsed}s"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo
    echo "- total: ${bootstrap_total_elapsed}s"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ -n "$KPI_BASELINE_SEC" ]; then
  if ! is_non_negative_int "$KPI_BASELINE_SEC"; then
    echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_BASELINE_SEC must be integer seconds" >&2
    exit 1
  fi
  if ! is_non_negative_int "$KPI_REDUCTION_PCT"; then
    echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT must be integer percent" >&2
    exit 1
  fi
  if [ "$KPI_REDUCTION_PCT" -ge 100 ]; then
    echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT must be < 100" >&2
    exit 1
  fi
  target_sec=$((KPI_BASELINE_SEC * (100 - KPI_REDUCTION_PCT) / 100))
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "- kpi baseline: ${KPI_BASELINE_SEC}s"
      echo "- kpi target (${KPI_REDUCTION_PCT}%): <= ${target_sec}s"
      echo "- kpi actual: ${bootstrap_total_elapsed}s"
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
  if [ "$bootstrap_total_elapsed" -gt "$target_sec" ]; then
    echo "bootstrap gate failed: KPI target missed (baseline=${KPI_BASELINE_SEC}s target<=${target_sec}s actual=${bootstrap_total_elapsed}s)" >&2
    exit 1
  fi
fi

echo "bootstrap gate passed: hash=$HASH_STAGE1 total=${bootstrap_total_elapsed}s"
