#!/usr/bin/env bash
# moonrun_wt import-surface drift guard.
#
# Dumps the moon `--target wasm` import set from the stage1 compile +
# check artifacts and diffs against the checked-in baseline at
# `tools/moonrun_wasmtime/expected_imports.txt`. Fails if anything
# changed.
#
# Rationale: moonrun_wt manually registers every host import in
# `register_imports()`. If the moonbit toolchain emits a new import,
# the only signal today is a runtime "unknown import" trap deep inside
# a bench run. This script makes the drift visible at PR time.
#
# On legitimate drift (new moonbit feature pulled in):
#   1. Implement the import in tools/moonrun_wasmtime/src/main.rs
#   2. Re-run `scripts/test_moonrun_wt_parity.sh` to verify byte-parity
#      with moonrun is preserved on the bench cases
#   3. Refresh the baseline with `--update` (commits the new import set)
#
# Usage:
#   scripts/check_moonrun_wt_imports.sh           # check
#   scripts/check_moonrun_wt_imports.sh --update  # rewrite baseline
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

UPDATE=0
if [ "${1:-}" = "--update" ]; then UPDATE=1; fi

export PATH="${MOON_HOME:-$HOME/.moon}/bin:$PATH"

WT_BIN="${MOONRUN_WT_BIN:-$PROJECT_ROOT/tools/moonrun_wasmtime/target/release/moonrun_wt}"
if [ ! -x "$WT_BIN" ]; then
  echo "[imports] building moonrun_wt..."
  (cd "$PROJECT_ROOT/tools/moonrun_wasmtime" && cargo build --release >&2)
fi
if [ ! -x "$WT_BIN" ]; then
  echo "check-moonrun-wt-imports: moonrun_wt build did not produce $WT_BIN" >&2
  exit 1
fi

# Prefer opt'd artifacts (canonical CI shape); fall back to release / debug.
resolve_pair() {
  for prof in opt release debug; do
    case "$prof" in
      opt)
        local c="$PROJECT_ROOT/_build/wasm/opt/vibe_compile_wasi.wasm"
        local k="$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.wasm"
        ;;
      release)
        local c="$PROJECT_ROOT/_build/wasm/release/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
        local k="$PROJECT_ROOT/_build/wasm/release/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
        ;;
      debug)
        local c="$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"
        local k="$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
        ;;
    esac
    if [ -f "$c" ] && [ -f "$k" ]; then
      echo "$prof|$c|$k"
      return 0
    fi
  done
  return 1
}

PAIR="$(resolve_pair || true)"
if [ -z "$PAIR" ]; then
  echo "check-moonrun-wt-imports: stage1 wasm not built. Run:" >&2
  echo "  moon build --target wasm src/cmd/vibe_compile_wasi src/cmd/vibe_check_wasi" >&2
  exit 1
fi
PROFILE="${PAIR%%|*}"
REST="${PAIR#*|}"
COMPILE_WASM="${REST%%|*}"
CHECK_WASM="${REST#*|}"

echo "[imports] profile=${PROFILE}"
echo "[imports] compile=${COMPILE_WASM#${PROJECT_ROOT}/}"
echo "[imports] check  =${CHECK_WASM#${PROJECT_ROOT}/}"

BASELINE="$PROJECT_ROOT/tools/moonrun_wasmtime/expected_imports.txt"
ACTUAL="$(mktemp /tmp/moonrun_wt_imports.XXXXXX)"
trap 'rm -f "$ACTUAL"' EXIT

{
  "$WT_BIN" --dump-imports "$COMPILE_WASM"
  "$WT_BIN" --dump-imports "$CHECK_WASM"
} | sort -u > "$ACTUAL"

if [ "$UPDATE" = "1" ]; then
  cp "$ACTUAL" "$BASELINE"
  echo "[imports] baseline updated: ${BASELINE#${PROJECT_ROOT}/}"
  wc -l < "$BASELINE" | awk '{ print "[imports] entries:", $1 }'
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "check-moonrun-wt-imports: baseline missing at ${BASELINE#${PROJECT_ROOT}/}" >&2
  echo "  Run with --update after verifying every entry is handled." >&2
  exit 1
fi

if diff -u "$BASELINE" "$ACTUAL" > /tmp/moonrun_wt_imports.diff; then
  count="$(wc -l < "$BASELINE" | tr -d ' ')"
  echo "[imports] OK — ${count} entries match baseline"
  exit 0
fi

echo "[imports] DRIFT detected — moon --target wasm import surface diverged from baseline" >&2
echo "[imports] (baseline: ${BASELINE#${PROJECT_ROOT}/})" >&2
echo >&2
sed 's/^/  /' /tmp/moonrun_wt_imports.diff >&2
echo >&2
echo "[imports] If this is a legitimate moonbit toolchain change:" >&2
echo "  1. Add a linker.func_wrap(...) for any new imports in" >&2
echo "     tools/moonrun_wasmtime/src/main.rs" >&2
echo "  2. Run: scripts/test_moonrun_wt_parity.sh" >&2
echo "  3. Run: scripts/check_moonrun_wt_imports.sh --update" >&2
exit 1
