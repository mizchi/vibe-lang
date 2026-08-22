#!/usr/bin/env bash
# Compile and run every probe in eval/book-review/probes/ against the
# CURRENT stage2, printing a per-probe report (compile ok/fail, the
# diagnostic if any, run output if it compiled). The report is the
# measurement — a probe that fails to compile is data, not a harness
# error, so this script always exits 0 unless the harness itself broke.
#
# usage: bash eval/book-review/run_probes.sh [probe.vibe ...]
set -uo pipefail

cd "$(dirname "$0")/../.."
OUT_DIR=_build/evalprobe-book
mkdir -p "$OUT_DIR"

# Same "which compiler answered?" discipline as eval/lang-review: the
# subject is the current compiler's behavior and diagnostic text.
S2="${BOOK_REVIEW_STAGE2:-}"
if [ -z "$S2" ] || [ ! -f "$S2" ]; then
  S2=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm
fi
if [ ! -f "$S2" ]; then
  echo "[book-review] no stage2 found. Build one first:" >&2
  echo "[book-review]   bash scripts/generations.sh build" >&2
  echo "[book-review] or pass BOOK_REVIEW_STAGE2=<stage2.wasm>." >&2
  echo "[book-review] Refusing to measure the committed seed silently." >&2
  exit 2
fi
echo "[book-review] compiler: $S2"

probes=("$@")
if [ ${#probes[@]} -eq 0 ]; then
  probes=(eval/book-review/probes/p*.vibe)
fi

for src in "${probes[@]}"; do
  name=$(basename "$src" .vibe)
  wasm="$OUT_DIR/$name.wasm"
  rm -f "$wasm" "$wasm.diag"
  echo ""
  echo "=== $name"
  case "$name" in
    *assert*)
      # test-block probes go through vibe test, not the compile lane
      VIBE_TEST_CLI_WASM="$S2" bash scripts/vibe_test.sh "$src" 2>&1 | sed 's/^/    /'
      continue
      ;;
  esac
  if VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$S2" "$src" "$wasm" main >"$OUT_DIR/$name.compile.log" 2>&1; then
    echo "--- compiles; run output:"
    bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$wasm" \
      2>"$OUT_DIR/$name.run.err" | sed 's/^/    /'
    if [ -s "$OUT_DIR/$name.run.err" ]; then
      echo "--- run stderr:"
      sed 's/^/    /' "$OUT_DIR/$name.run.err"
    fi
  else
    echo "--- does NOT compile; diagnostic:"
    if [ -s "$wasm.diag" ]; then
      sed 's/^/    /' "$wasm.diag"
    else
      echo "    (no .diag sidecar; compile log follows)"
      tail -5 "$OUT_DIR/$name.compile.log" | sed 's/^/    /'
    fi
  fi
done
