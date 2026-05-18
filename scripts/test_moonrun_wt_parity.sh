#!/usr/bin/env bash
# moonrun vs moonrun_wt output parity gate.
#
# Runs the selfhost stage1 compile (and checker exit/stdout) under both
# runtimes against the bench/selfhost_perf case list and verifies the
# emitted `.wasm` is byte-identical. Treat this as a release-blocker for
# any change to `tools/moonrun_wasmtime/` or the moon `--target wasm`
# import surface.
#
# Usage:
#   scripts/test_moonrun_wt_parity.sh [case ...]
# Env:
#   VIBE_PARITY_WASM_PROFILE   debug | release | opt   (default: opt fallback debug)
#   VIBE_PARITY_CASES_FILE     case list (default: bench/selfhost_perf/cases.txt)
#   VIBE_PARITY_KEEP_TMP=1     don't clean staged outputs (debug)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export PATH="${MOON_HOME:-$HOME/.moon}/bin:$PATH"

if ! command -v moonrun >/dev/null 2>&1; then
  echo "test-moonrun-wt-parity: moonrun not on PATH" >&2
  exit 1
fi

WT_BIN="${MOONRUN_WT_BIN:-$PROJECT_ROOT/tools/moonrun_wasmtime/target/release/moonrun_wt}"
if [ ! -x "$WT_BIN" ]; then
  echo "[parity] building moonrun_wt..."
  (cd "$PROJECT_ROOT/tools/moonrun_wasmtime" && cargo build --release >&2)
fi
if [ ! -x "$WT_BIN" ]; then
  echo "test-moonrun-wt-parity: moonrun_wt build did not produce $WT_BIN" >&2
  exit 1
fi

resolve_compile_wasm() {
  local profile="$1"
  case "$profile" in
    opt)
      local p="$PROJECT_ROOT/_build/wasm/opt/vibe_compile_wasi.wasm"
      [ -f "$p" ] && echo "$p" && return 0
      ;;
    release)
      echo "$PROJECT_ROOT/_build/wasm/release/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
      return 0
      ;;
    debug)
      echo "$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
      return 0
      ;;
  esac
  return 1
}

PROFILE="${VIBE_PARITY_WASM_PROFILE:-opt}"
COMPILE_WASM="$(resolve_compile_wasm "$PROFILE" || true)"
if [ -z "${COMPILE_WASM:-}" ] || [ ! -f "$COMPILE_WASM" ]; then
  # Try fallbacks in priority order.
  for p in opt release debug; do
    COMPILE_WASM="$(resolve_compile_wasm "$p" || true)"
    if [ -n "${COMPILE_WASM:-}" ] && [ -f "$COMPILE_WASM" ]; then
      PROFILE="$p"
      break
    fi
  done
fi
if [ -z "${COMPILE_WASM:-}" ] || [ ! -f "$COMPILE_WASM" ]; then
  echo "test-moonrun-wt-parity: no stage1 compile wasm found (build with moon build --target wasm src/cmd/vibe_compile_wasi)" >&2
  exit 1
fi

CWASM="${COMPILE_WASM%.wasm}.cwasm"
if [ ! -f "$CWASM" ] || [ "$COMPILE_WASM" -nt "$CWASM" ]; then
  "$WT_BIN" --precompile "$COMPILE_WASM" -o "$CWASM" >&2
fi

CASES_FILE="${VIBE_PARITY_CASES_FILE:-$PROJECT_ROOT/bench/selfhost_perf/cases.txt}"
cases=()
if [ "$#" -gt 0 ]; then
  cases=("$@")
else
  while IFS= read -r row; do
    row="${row#"${row%%[![:space:]]*}"}"
    [ -z "$row" ] && continue
    case "$row" in
      \#*) continue ;;
    esac
    cases+=("$row")
  done < "$CASES_FILE"
fi

if [ "${#cases[@]}" -eq 0 ]; then
  echo "test-moonrun-wt-parity: no cases" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/moonrun_wt_parity.XXXXXX)"
cleanup() {
  [ -n "${VIBE_PARITY_KEEP_TMP:-}" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[parity] profile=${PROFILE} wasm=${COMPILE_WASM#${PROJECT_ROOT}/}"
echo "[parity] cases=${#cases[@]}"

fail=0
for case_rel in "${cases[@]}"; do
  case_path="$PROJECT_ROOT/$case_rel"
  if [ ! -f "$case_path" ]; then
    echo "[parity] SKIP $case_rel (not found)" >&2
    continue
  fi
  safe="$(echo "$case_rel" | tr '/: ' '___')"
  out_m="$TMP_DIR/${safe}.moonrun.wasm"
  out_w="$TMP_DIR/${safe}.wt.wasm"

  if ! moonrun "$COMPILE_WASM" compile-lite --wasm-linear --no-dce "$case_path" -o "$out_m" >/dev/null 2>"$TMP_DIR/$safe.moonrun.stderr"; then
    echo "[parity] FAIL $case_rel (moonrun compile failed; see $TMP_DIR/$safe.moonrun.stderr)" >&2
    fail=1
    continue
  fi
  if ! "$WT_BIN" "$CWASM" compile-lite --wasm-linear --no-dce "$case_path" -o "$out_w" >/dev/null 2>"$TMP_DIR/$safe.wt.stderr"; then
    echo "[parity] FAIL $case_rel (moonrun_wt compile failed; see $TMP_DIR/$safe.wt.stderr)" >&2
    fail=1
    continue
  fi

  hm="$(sha256sum "$out_m" | cut -d' ' -f1)"
  hw="$(sha256sum "$out_w" | cut -d' ' -f1)"
  sm="$(stat -c%s "$out_m")"
  sw="$(stat -c%s "$out_w")"
  if [ "$hm" = "$hw" ]; then
    printf "[parity] OK   %s  %s bytes\n" "$case_rel" "$sm"
  else
    printf "[parity] DIFF %s  moonrun=%s (%s bytes)  wt=%s (%s bytes)\n" "$case_rel" "${hm:0:16}" "$sm" "${hw:0:16}" "$sw" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "[parity] FAILED" >&2
  exit 1
fi
echo "[parity] all ${#cases[@]} cases byte-identical"
