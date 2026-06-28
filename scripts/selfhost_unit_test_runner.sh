#!/usr/bin/env bash
# Selfhost unit-test runner (#531 / #535).
#
# Compiles + runs every allowlisted `*_test.vibe` through the moon-free selfhost
# compiler. A file PASSES when it compiles (the compiler emits a `_start` that
# runs the file's `test {}` blocks, selected via the `__no_entry__` entry) AND
# that `_start` runs to completion (a failing `assert` traps the module).
#
# This is the regression net for language/stdlib features the compiler itself
# does not exercise during self-build. The retired MoonBit-host suite ran the
# full corpus; the selfhost compiler's prelude/parser is a subset, so we gate
# the allowlisted subset that passes today and ratchet it upward over time
# (#531). New failures in any allowlisted file fail the run (and CI).
#
# Modes:
#   (default)            run the allowlist; exit non-zero if any file fails
#   --list               print the allowlist and exit
#   --scan               compile+run EVERY discovered *_test.vibe, print a full
#                        pass/fail report + any allowlist drift, then exit 0
#   --update-allowlist   rescan all *_test.vibe and overwrite the allowlist with
#                        the passing set (run after intentionally widening it)
#
# Stage2 selection: reuse $VIBE_SELFHOST_STAGE2_WASM when set and non-empty
# (CI reuses the gate's freshly-built stage2 to avoid a second selfbuild);
# otherwise build a fresh seed->stage1->stage2 generation and use its stage2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

ALLOWLIST="${VIBE_SELFHOST_UNIT_TEST_ALLOWLIST:-$ROOT_DIR/scripts/selfhost_unit_test_allowlist.txt}"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

mode="run"
case "${1:-}" in
  --list) mode="list" ;;
  --scan) mode="scan" ;;
  --update-allowlist) mode="update" ;;
  "") mode="run" ;;
  *) echo "unknown argument: $1 (expected --list|--scan|--update-allowlist)" >&2; exit 2 ;;
esac

if [ "$mode" = "list" ]; then
  cat "$ALLOWLIST"
  exit 0
fi

# --- obtain a stage2 compiler -------------------------------------------------
S2=""
if [ -n "${VIBE_SELFHOST_STAGE2_WASM:-}" ] && [ -s "${VIBE_SELFHOST_STAGE2_WASM}" ]; then
  S2="$VIBE_SELFHOST_STAGE2_WASM"
  echo "[unit-test-runner] using prebuilt stage2: $S2"
else
  outdir="$ROOT_DIR/_build/_unit_test_gen"
  echo "[unit-test-runner] building fresh stage2 (seed->stage1->stage2)"
  rm -f "$ROOT_DIR"/_build/vibe_selfhost_*.tsv
  bash scripts/selfhost_generations.sh build --out-dir "$outdir" >/dev/null
  S2="$outdir/stage2.wasm"
fi
[ -s "$S2" ] || { echo "[unit-test-runner] FAIL: no stage2 compiler available" >&2; exit 1; }

# --- compile + run one test file; 0 = pass, 1 = fail --------------------------
# A heavy file can trap the compiler with no diagnostic (the bump-heap hits a
# guard page mid-compile) — that's a nondeterministic heap-marginal OOM, not a
# regression, so retry it. Deterministic failures are NOT retried: a real
# compile error writes a `.diag` sidecar, and a failing test assert traps at
# runtime — both are stable, so the first observation is final.
run_one() {
  local f="$1"
  local attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    local out; out="$(mktemp -t vibe-unit-XXXXXX.wasm)"
    rm -f "$out" "$out.diag"
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
      bash "$RUNNER" --invoke cli_main "$S2" "$f" "$out" __no_entry__ >/dev/null 2>&1 || true
    if [ -s "$out" ]; then
      if VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$RUNNER" --invoke _start "$out" >/dev/null 2>&1; then
        rm -f "$out" "$out.diag"; return 0
      fi
      LAST_DIAG="(test assertion trapped at runtime)"
      rm -f "$out" "$out.diag"; return 1
    fi
    if [ -s "$out.diag" ]; then
      LAST_DIAG="$(cat "$out.diag" 2>/dev/null | head -1)"
      rm -f "$out" "$out.diag"; return 1
    fi
    # No wasm and no diagnostic = compiler trapped (heap-marginal). Retry.
    LAST_DIAG="(compile trapped with no diagnostic — heap-marginal, $attempt/3)"
    rm -f "$out" "$out.diag"
  done
  return 1
}

discover() { find examples vibe -name '*_test.vibe' 2>/dev/null | sed "s@^$ROOT_DIR/@@" | sed 's@^\./@@' | sort; }

# --- --scan / --update-allowlist: rescan everything ---------------------------
if [ "$mode" = "scan" ] || [ "$mode" = "update" ]; then
  passing="$(mktemp)"; : > "$passing"
  npass=0; nfail=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if run_one "$f"; then
      echo "$f" >> "$passing"; npass=$((npass+1))
    else
      nfail=$((nfail+1))
      [ "$mode" = "scan" ] && echo "  fail: $f -- ${LAST_DIAG:-}"
    fi
  done < <(discover)
  echo "[unit-test-runner] scan: PASS=$npass FAIL=$nfail"
  if [ "$mode" = "update" ]; then
    {
      echo "# Selfhost unit-test runner allowlist (#531 / #535)."
      echo "# Every *_test.vibe here compiles + runs clean through the selfhost"
      echo "# compiler. Regenerate after widening: scripts/selfhost_unit_test_runner.sh --update-allowlist"
      echo "# Ratchet target: the full *_test.vibe corpus as the selfhost prelude/parser grows."
      cat "$passing"
    } > "$ALLOWLIST"
    echo "[unit-test-runner] wrote $(wc -l < "$passing") entries to $ALLOWLIST"
  else
    # Report drift vs the committed allowlist (informational; --scan never fails).
    comm -13 <(grep -vE '^\s*#' "$ALLOWLIST" | sed '/^$/d' | sort) <(sort "$passing") > "$ROOT_DIR/_build/.unit_newpass" || true
    if [ -s "$ROOT_DIR/_build/.unit_newpass" ]; then
      echo "[unit-test-runner] newly-passing (not yet in allowlist — consider --update-allowlist):"
      sed 's/^/  + /' "$ROOT_DIR/_build/.unit_newpass"
    fi
    rm -f "$ROOT_DIR/_build/.unit_newpass"
  fi
  rm -f "$passing"
  exit 0
fi

# --- default: run the allowlist, fail on any regression -----------------------
[ -f "$ALLOWLIST" ] || { echo "[unit-test-runner] FAIL: allowlist not found: $ALLOWLIST" >&2; exit 1; }
total=0; fails=0
while IFS= read -r f; do
  case "$f" in ''|\#*) continue ;; esac
  total=$((total+1))
  if [ ! -f "$f" ]; then
    echo "[unit-test-runner] FAIL: allowlisted file missing on disk: $f" >&2; fails=$((fails+1)); continue
  fi
  if run_one "$f"; then
    echo "ok:   $f"
  else
    echo "FAIL: $f -- ${LAST_DIAG:-}" >&2; fails=$((fails+1))
  fi
done < "$ALLOWLIST"

echo "[unit-test-runner] $((total-fails))/$total allowlisted unit-test files passed"
if [ "$fails" -ne 0 ]; then
  echo "[unit-test-runner] FAIL: $fails allowlisted unit-test file(s) regressed" >&2
  exit 1
fi
echo "[unit-test-runner] ok"
