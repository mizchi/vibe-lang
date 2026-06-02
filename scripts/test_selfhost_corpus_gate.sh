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

PASS=0
FAIL=0
TIMEOUTS=0
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
    printf '%s\tok\t\n' "$f" >> "$SUMMARY_TSV"
  else
    snippet="$(grep -m1 -iE 'Error string|error|parse|type|trap|unsupported|unexpected|unknown|expected' "$errlog" 2>/dev/null | sed 's/^[[:space:]]*//' | head -c 200)"
    [ -z "$snippet" ] && snippet="$(grep -v 'crash debug' "$errlog" 2>/dev/null | head -n1 | head -c 200)"
    if [ "$st" -eq 124 ]; then TIMEOUTS=$((TIMEOUTS + 1)); snippet="(timeout ${TIMEOUT_SEC}s)"; fi
    FAIL=$((FAIL + 1))
    printf '%s\tfail(%d)\t%s\n' "$f" "$st" "$snippet" >> "$SUMMARY_TSV"
    printf '  FAIL [%d] %s\n        %s\n' "$st" "$f" "$snippet"
  fi
done

echo ""
echo "===================== selfhost corpus gate ====================="
echo "  files: ${#FILES[@]}   pass: $PASS   fail: $FAIL   (timeouts: $TIMEOUTS)"
echo "  full results: $SUMMARY_TSV"
echo "================================================================"

if [ "$GATE" -eq 1 ] && [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
