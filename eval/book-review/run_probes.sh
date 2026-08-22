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
# subject is the current compiler's behavior and diagnostic text, so a
# wrong compiler must be a loud error, never a silent fallback.
if [ -n "${BOOK_REVIEW_STAGE2:-}" ]; then
  # An explicit override is the caller's deliberate choice -- but a
  # mistyped path must not fall through to whatever is on disk.
  if [ ! -f "$BOOK_REVIEW_STAGE2" ]; then
    echo "[book-review] BOOK_REVIEW_STAGE2 is set but does not exist:" >&2
    echo "[book-review]   $BOOK_REVIEW_STAGE2" >&2
    exit 2
  fi
  S2="$BOOK_REVIEW_STAGE2"
else
  gen_dir=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)
  S2="${gen_dir}stage2.wasm"
  if [ -z "$gen_dir" ] || [ ! -f "$S2" ]; then
    echo "[book-review] no stage2 found. Build one first:" >&2
    echo "[book-review]   bash scripts/generations.sh build" >&2
    echo "[book-review] or pass BOOK_REVIEW_STAGE2=<stage2.wasm>." >&2
    echo "[book-review] Refusing to measure the committed seed silently." >&2
    exit 2
  fi
  # Generation dirs are named <gen>_<shortsha>; a generation built from
  # another commit is not this checkout's compiler.
  gen_sha=$(basename "$gen_dir")
  gen_sha="${gen_sha##*_}"
  head_sha=$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
  if [ "$gen_sha" != "${head_sha:0:${#gen_sha}}" ]; then
    echo "[book-review] newest stage2 is from commit $gen_sha, HEAD is $head_sha." >&2
    echo "[book-review] Its answers would describe THAT compiler, not this checkout." >&2
    echo "[book-review] Rebuild (bash scripts/generations.sh build), or pass the" >&2
    echo "[book-review] compiler you mean explicitly: BOOK_REVIEW_STAGE2=$S2" >&2
    exit 2
  fi
fi
echo "[book-review] compiler: $S2"

probes=("$@")
if [ ${#probes[@]} -eq 0 ]; then
  probes=(eval/book-review/probes/p*.vibe)
fi

harness_fail=0
for src in "${probes[@]}"; do
  if [ ! -f "$src" ]; then
    # An unexpanded glob or a typo must not be recorded as a probe
    # result (the compile lane would report it as a diagnostic).
    echo ""
    echo "=== $src"
    echo "--- HARNESS ERROR: probe file not found (run from the repo root," >&2
    echo "    e.g. eval/book-review/probes/p01_*.vibe)" >&2
    harness_fail=1
    continue
  fi
  name=$(basename "$src" .vibe)
  wasm="$OUT_DIR/$name.wasm"
  rm -f "$wasm" "$wasm.diag"
  echo ""
  echo "=== $name"
  case "$name" in
    *assert*)
      # test-block probes go through vibe test, not the compile lane
      test_log="$OUT_DIR/$name.test.log"
      VIBE_TEST_CLI_WASM="$S2" bash scripts/vibe_test.sh "$src" >"$test_log" 2>&1
      sed 's/^/    /' "$test_log"
      # A test-lane answer contains a per-test report (an `ok:` line or
      # a `failing test:` line) -- an assertion FAILURE is probe data.
      # A run that produced neither (seed setup failure, invalid
      # compiler artifact, compile failure before any test ran) is
      # infrastructure, not a compiler answer. Probes that are MEANT
      # to fail compilation belong on the compile lane, not here.
      if ! grep -qE 'failing test:|^ok[[:space:]]' "$test_log"; then
        echo "--- HARNESS ERROR: test lane produced no test report;"
        echo "    this is not a compiler answer."
        harness_fail=1
      fi
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
    if [ -s "$wasm.diag" ]; then
      echo "--- does NOT compile; diagnostic:"
      sed 's/^/    /' "$wasm.diag"
    else
      # No sidecar means the RUNNER failed (bad artifact, host error),
      # not that the compiler rejected the probe -- recording it as a
      # compiler answer would corrupt the round.
      echo "--- HARNESS ERROR: runner failed without a .diag sidecar;"
      echo "    this is not a compiler answer. Compile log tail:"
      tail -5 "$OUT_DIR/$name.compile.log" | sed 's/^/    /'
      harness_fail=1
    fi
  fi
done

if [ "$harness_fail" -ne 0 ]; then
  echo ""
  echo "[book-review] HARNESS ERRORS occurred -- results above are incomplete." >&2
  exit 2
fi
