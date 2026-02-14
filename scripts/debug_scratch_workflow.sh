#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BUILD_MODE="${VIBE_SCRATCH_CLI_BUILD:-debug}" # debug|release|skip
RUNS="${VIBE_SCRATCH_RUNS:-20}"
TMP_PARENT="${VIBE_SCRATCH_TMP_PARENT:-$ROOT_DIR/tmp/tmp-hash}"
APP_NAME="${VIBE_SCRATCH_APP_NAME:-app}"
KEEP_SUCCESS="${VIBE_SCRATCH_KEEP_SUCCESS:-0}"
CHECK_MAIN="${VIBE_SCRATCH_CHECK_MAIN:-1}"

if [ -n "${VIBE_SCRATCH_CLI_BIN:-}" ]; then
  CLI_BIN="$VIBE_SCRATCH_CLI_BIN"
else
  if [ "$BUILD_MODE" = "release" ]; then
    CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
  else
    CLI_BIN="$ROOT_DIR/target/native/debug/build/cmd/vibe/vibe.exe"
  fi
fi

build_cli_if_needed() {
  case "$BUILD_MODE" in
    debug)
      moon build --target native src/cmd/vibe
      ;;
    release)
      moon build --target native --release src/cmd/vibe
      ;;
    skip)
      ;;
    *)
      echo "VIBE_SCRATCH_CLI_BUILD must be debug|release|skip (actual: $BUILD_MODE)" >&2
      exit 1
      ;;
  esac
}

run_cmd() {
  local log_path="$1"
  shift
  {
    printf '+'
    for arg in "$@"; do
      printf ' %s' "$arg"
    done
    printf '\n'
  } >>"$log_path"
  "$@" >>"$log_path" 2>&1
}

run_iteration() {
  local app_dir="$1"
  local log_path="$2"

  run_cmd "$log_path" "$CLI_BIN" new "$app_dir"
  (
    cd "$app_dir"
    run_cmd "$log_path" "$CLI_BIN" eval "let base = 10"
    run_cmd "$log_path" "$CLI_BIN" eval "let inc = (x: Int) -> Int { x + base }"
    run_cmd "$log_path" "$CLI_BIN" eval "let answer = inc(2)"
    run_cmd "$log_path" "$CLI_BIN" eval "export { answer }"
    run_cmd "$log_path" "$CLI_BIN" eval --inspect-scope
    run_cmd "$log_path" "$CLI_BIN" finalize --library --export main.vibe
    run_cmd "$log_path" "$CLI_BIN" normalize --write main.vibe
    if [ "$CHECK_MAIN" = "1" ]; then
      run_cmd "$log_path" "$CLI_BIN" check main.vibe
    fi
  )
}

build_cli_if_needed
if [ ! -x "$CLI_BIN" ]; then
  echo "vibe cli not found: $CLI_BIN" >&2
  exit 1
fi

mkdir -p "$TMP_PARENT"
passes=0
failures=0

for i in $(seq 1 "$RUNS"); do
  stamp="$(date +%Y%m%d-%H%M%S)"
  run_id="$stamp-$RANDOM-$i"
  run_root="$TMP_PARENT/$run_id"
  app_dir="$run_root/$APP_NAME"
  log_path="$run_root/workflow.log"

  mkdir -p "$run_root"
  {
    echo "iteration=$i/$RUNS"
    echo "run_id=$run_id"
    echo "run_root=$run_root"
    echo "app_dir=$app_dir"
  } >"$log_path"

  if run_iteration "$app_dir" "$log_path"; then
    passes=$((passes + 1))
    if [ "$KEEP_SUCCESS" = "1" ]; then
      echo "ok   iteration=$i run_root=$run_root"
    else
      rm -rf "$run_root"
      echo "ok   iteration=$i"
    fi
  else
    failures=$((failures + 1))
    echo "fail iteration=$i run_root=$run_root log=$log_path"
  fi
done

echo "summary: passes=$passes failures=$failures runs=$RUNS tmp_parent=$TMP_PARENT"
if [ "$failures" -gt 0 ]; then
  exit 1
fi
