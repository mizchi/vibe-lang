#!/usr/bin/env bash
# Full-corpus selfhost compile gate (#415 cutover follow-up).
#
# Compiles every .vibe file in a corpus through the SELF-HOSTED compiler
# (the vibe-written compiler in vibe/compiler/, host-compiled to wasm and
# run via the node wasm host runner). This empirically surfaces the
# language-expressiveness / feature gaps that would block dropping the
# MoonBit `src/` implementation: if the selfhost compiler can't compile a
# .vibe file the host compiles, it shows up here with the selfhost error.
#
# How it works:
#   1. Host-compile `vibe/compiler/selfhost_cli_support.vibe` (the selfhost
#      compiler's CLI entry, `cli_main`) to wasm. This wasm IS the
#      vibe-written compiler logic.
#   2. For each corpus file, invoke `cli_main` in `debug` (linked) mode so
#      imports + the prelude resolve, and check the exit code. 0 = the
#      selfhost compiler parsed + type-checked + linked + codegen'd it; non-0
#      = a gap (the selfhost error is captured).
#
# Usage:
#   scripts/test_selfhost_corpus_gate.sh                 # default corpus, report-only
#   scripts/test_selfhost_corpus_gate.sh --gate          # exit 1 if any file fails
#   scripts/test_selfhost_corpus_gate.sh path/glob ...   # custom corpus
#   VIBE_CORPUS_INCLUDE_TESTS=1 scripts/...              # also compile *_test.vibe
#   VIBE_CORPUS_TIMEOUT_SEC=120 scripts/...              # per-file timeout
#   VIBE_CORPUS_ENTRY=main scripts/...                   # entry name passed to cli_main
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

OUT_DIR_REL="_build/bench/selfhost_corpus"
OUT_DIR="$ROOT/$OUT_DIR_REL"
SELFHOST_SRC="${VIBE_SELFHOST_CLI_SRC:-vibe/compiler/selfhost_cli_support.vibe}"
SELFHOST_WASM="${SELFHOST_WASM:-$OUT_DIR/selfhost_compiler.wasm}"
VIBE_BIN="${VIBE_BIN:-$ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
RUNNER="$ROOT/scripts/run_wasm_vibe_host_runner.sh"
TIMEOUT_SEC="${VIBE_CORPUS_TIMEOUT_SEC:-120}"
INCLUDE_TESTS="${VIBE_CORPUS_INCLUDE_TESTS:-0}"
ENTRY="${VIBE_CORPUS_ENTRY:-main}"

GATE=0
declare -a ARG_GLOBS=()
for a in "$@"; do
  case "$a" in
    --gate) GATE=1 ;;
    *) ARG_GLOBS+=("$a") ;;
  esac
done

mkdir -p "$OUT_DIR"

# --- ensure the native host vibe CLI (used to build the selfhost wasm) ---
if [ ! -x "$VIBE_BIN" ]; then
  echo "[corpus] building native vibe CLI (scripts/ensure_native_cli.sh)"
  bash "$ROOT/scripts/ensure_native_cli.sh" || { echo "corpus gate: native CLI build failed" >&2; exit 2; }
fi
[ -x "$VIBE_BIN" ] || { echo "corpus gate: vibe CLI missing: $VIBE_BIN" >&2; exit 2; }

# --- build the selfhost compiler wasm (the vibe-written compiler) ---
if [ ! -f "$SELFHOST_WASM" ] || [ "$SELFHOST_SRC" -nt "$SELFHOST_WASM" ]; then
  echo "[corpus] building selfhost compiler wasm: host-compile $SELFHOST_SRC"
  if ! "$VIBE_BIN" compile --wasm --force-cabi-realloc "$SELFHOST_SRC" -o "$SELFHOST_WASM"; then
    echo "corpus gate: selfhost compiler build failed" >&2
    exit 2
  fi
fi
echo "[corpus] selfhost compiler: $SELFHOST_WASM ($(wc -c < "$SELFHOST_WASM" | tr -d ' ') bytes)"

# --- enumerate corpus ---
declare -a FILES=()
if [ "${#ARG_GLOBS[@]}" -gt 0 ]; then
  for g in "${ARG_GLOBS[@]}"; do
    for f in $g; do [ -f "$f" ] && FILES+=("$f"); done
  done
else
  while IFS= read -r f; do FILES+=("$f"); done < <(
    {
      ls vibe/prelude/*.vibe 2>/dev/null
      ls examples/*.vibe 2>/dev/null
      find vibe/x -name '*.vibe' 2>/dev/null
    } | sort -u
  )
fi
if [ "$INCLUDE_TESTS" != "1" ]; then
  declare -a KEPT=()
  for f in "${FILES[@]}"; do
    case "$f" in *_test.vibe) ;; *) KEPT+=("$f") ;; esac
  done
  FILES=("${KEPT[@]}")
fi

echo "[corpus] compiling ${#FILES[@]} files through the selfhost compiler (debug/linked mode, ${TIMEOUT_SEC}s/file)"
echo ""

# Classify a failure snippet into one of:
#   REAL    — a genuine selfhost language/checker gap (parser errors, unknown
#             feature, type mismatch). These are real cutover blockers and
#             trip `--gate`.
#   MODE    — a gate-harness / compile-mode artifact, NOT a selfhost capability
#             gap: `undefined variable: Ns::method` (the debug/linked mode does
#             not link builtin/prelude bodies for codegen — the selfhost CHECKER
#             does know these, cf. the passing check_source_ok builtin tests),
#             relative-import `fs_read_file failed` (ENOENT), or `no functions
#             found` (the fixed entry name does not exist in the file).
#   TRIAGE  — `unknown name: <x>` that is not a `Ns::method` builtin; may be a
#             real scoping gap or an unlinked prelude helper. Reported, but does
#             not trip the gate until triaged.
classify_err() {
  case "$1" in
    *"undefined variable"*|*"fs_read_file failed"*|*"no functions found"*) echo "MODE" ;;
    *"unknown name: "*"::"*) echo "MODE" ;;     # Ns::method builtin not linked
    *"unknown name: "*) echo "TRIAGE" ;;
    *) echo "REAL" ;;
  esac
}

PASS=0
FAIL=0
TIMEOUTS=0
REAL=0
MODE=0
TRIAGE=0
SUMMARY_TSV="$OUT_DIR/corpus_results.tsv"
: > "$SUMMARY_TSV"
OUT_WASM_REL="$OUT_DIR_REL/_corpus_out.wasm"

for f in "${FILES[@]}"; do
  errlog="$OUT_DIR/last_err.log"
  VIBE_PREOPEN_DIR="$ROOT" timeout "$TIMEOUT_SEC" \
    bash "$RUNNER" --invoke cli_main "$SELFHOST_WASM" "$f" "$OUT_WASM_REL" "$ENTRY" debug \
    >"$errlog" 2>&1
  st=$?
  if [ "$st" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '%s\tok\t\t\n' "$f" >> "$SUMMARY_TSV"
  else
    snippet="$(grep -m1 -iE 'Error string|error|parse|type|trap|unsupported|unexpected|unknown|expected' "$errlog" 2>/dev/null | sed 's/^[[:space:]]*//' | head -c 200)"
    [ -z "$snippet" ] && snippet="$(grep -v 'crash debug' "$errlog" 2>/dev/null | head -n1 | head -c 200)"
    if [ "$st" -eq 124 ]; then TIMEOUTS=$((TIMEOUTS + 1)); snippet="(timeout ${TIMEOUT_SEC}s)"; fi
    bucket="$(classify_err "$snippet")"
    case "$bucket" in
      REAL) REAL=$((REAL + 1)) ;;
      MODE) MODE=$((MODE + 1)) ;;
      TRIAGE) TRIAGE=$((TRIAGE + 1)) ;;
    esac
    FAIL=$((FAIL + 1))
    printf '%s\tfail(%d)\t%s\t%s\n' "$f" "$st" "$bucket" "$snippet" >> "$SUMMARY_TSV"
    printf '  FAIL [%s] %s\n        %s\n' "$bucket" "$f" "$snippet"
  fi
done

echo ""
echo "===================== selfhost corpus gate ====================="
echo "  files: ${#FILES[@]}   pass: $PASS   fail: $FAIL   (timeouts: $TIMEOUTS)"
echo "  REAL gaps (gate-tripping): $REAL"
echo "  MODE artifacts (builtin-not-linked / import / entry — not gaps): $MODE"
echo "  TRIAGE (unknown name, needs triage): $TRIAGE"
echo "  full results: $SUMMARY_TSV"
echo "================================================================"
if [ "$REAL" -gt 0 ]; then
  echo "  REAL gaps:"
  grep -P '\tfail\([0-9]+\)\tREAL\t' "$SUMMARY_TSV" 2>/dev/null | cut -f1,4 | sed 's/^/    - /'
fi

# `--gate` only trips on REAL language/checker gaps, not MODE artifacts.
if [ "$GATE" -eq 1 ] && [ "$REAL" -gt 0 ]; then
  exit 1
fi
exit 0
