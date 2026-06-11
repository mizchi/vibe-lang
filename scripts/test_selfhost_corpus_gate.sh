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
#   1. Host-compile `vibe/cli/selfhost_entry.vibe` (the selfhost compiler's
#      CLI entry, `cli_main`) to wasm. This wasm IS the vibe-written compiler
#      logic.
#   2. For each corpus file, invoke `cli_main` in `debug` (linked) mode so
#      imports + the prelude resolve, and check the exit code. 0 = the
#      selfhost compiler parsed + type-checked + linked + codegen'd it; non-0
#      = a gap (the selfhost error is captured).
#
# Gate v2 (#492): compiles in `check` mode (linked parse + typecheck, no
# codegen) so the signal reflects real selfhost language/checker EXPRESSIVENESS.
# `--gate` is a regression tripwire against a committed REAL-gap baseline (green
# when the REAL-failing set equals the baseline; see CORPUS_BASELINE below).
#
# Usage:
#   scripts/test_selfhost_corpus_gate.sh                 # default corpus, report-only
#   scripts/test_selfhost_corpus_gate.sh --gate          # tripwire vs baseline
#   scripts/test_selfhost_corpus_gate.sh --update-baseline  # regenerate baseline
#   scripts/test_selfhost_corpus_gate.sh path/glob ...   # custom corpus
#   VIBE_CORPUS_MODE=debug scripts/...                  # codegen-path mode (old)
#   VIBE_CORPUS_INCLUDE_TESTS=1 scripts/...              # also compile *_test.vibe
#   VIBE_CORPUS_TIMEOUT_SEC=120 scripts/...              # per-file timeout
#   VIBE_CORPUS_ENTRY=main scripts/...                   # entry name passed to cli_main
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

OUT_DIR_REL="_build/bench/selfhost_corpus"
OUT_DIR="$ROOT/$OUT_DIR_REL"
SELFHOST_SRC="${VIBE_SELFHOST_CLI_SRC:-vibe/cli/selfhost_entry.vibe}"
case "$SELFHOST_SRC" in
  /*) SELFHOST_SRC_ABS="$SELFHOST_SRC" ;;
  *) SELFHOST_SRC_ABS="$ROOT/$SELFHOST_SRC" ;;
esac
SELFHOST_WASM="${SELFHOST_WASM:-$OUT_DIR/selfhost_compiler.wasm}"
RUNNER="$ROOT/scripts/run_wasm_vibe_host_runner.sh"
TIMEOUT_SEC="${VIBE_CORPUS_TIMEOUT_SEC:-120}"
INCLUDE_TESTS="${VIBE_CORPUS_INCLUDE_TESTS:-0}"
ENTRY="${VIBE_CORPUS_ENTRY:-main}"
# Gate v2 (#492): default to `check` mode (linked parse + typecheck, no codegen)
# so the signal reflects real selfhost language/checker EXPRESSIVENESS, without
# the `debug`-mode codegen builtin-body-linking confounder. `debug` is still
# available via VIBE_CORPUS_MODE=debug for codegen-path investigation.
COMPILE_MODE="${VIBE_CORPUS_MODE:-check}"
# Give the node wasm host runner extra JS stack for the selfhost compiler's
# recursive descent on large corpus files (e.g. regexp), so the recursion-depth
# ceiling (#492) does not masquerade as a checker REAL gap. Overridable.
export VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=4000}"

GATE=0
UPDATE_BASELINE=0
# Baseline of currently-known REAL-failing corpus files. `--gate` is green when
# the REAL-failing set equals the baseline, and trips on any divergence:
#   * a non-baselined file newly fails REAL  -> regression (a new selfhost gap)
#   * a baselined file now passes            -> baseline is stale, shrink it
# Regenerate with `--update-baseline` after intentionally changing the set.
BASELINE="${VIBE_CORPUS_BASELINE:-$ROOT/scripts/selfhost_corpus_baseline.txt}"
declare -a ARG_GLOBS=()
for a in "$@"; do
  case "$a" in
    --gate) GATE=1 ;;
    --update-baseline) UPDATE_BASELINE=1 ;;
    *) ARG_GLOBS+=("$a") ;;
  esac
done

mkdir -p "$OUT_DIR"

# --- build the selfhost compiler wasm (the vibe-written compiler) ---
echo "[corpus] resolving selfhost compiler wasm: $SELFHOST_SRC_ABS"
if ! SELFHOST_WASM="$(
  VIBE_SELFHOST_CLI_CORE_OUT_DIR="$(dirname "$SELFHOST_WASM")" \
  ENTRY_PATH="$SELFHOST_SRC_ABS" \
  STAGE1_CORE_WASM="$SELFHOST_WASM" \
  VIBE_SELFHOST_CLI_CORE_REBUILD="${VIBE_SELFHOST_CLI_CORE_REBUILD:-auto}" \
  bash "$ROOT/scripts/build_selfhost_cli_core.sh"
)"; then
  echo "corpus gate: selfhost compiler build failed" >&2
  exit 2
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

echo "[corpus] compiling ${#FILES[@]} files through the selfhost compiler (${COMPILE_MODE} mode, ${TIMEOUT_SEC}s/file)"
echo ""

# Classify a failure snippet into one of (Gate v2, `check` mode):
#   REAL    — a genuine selfhost checker/parser gap: parse errors, type
#             mismatches, `unknown name` (incl. unknown builtin `Ns::method` =
#             missing checker signature, and real scoping gaps). The `check`
#             mode actually type-checks (the old `debug` mode ran codegen only,
#             so it never surfaced these), so these are now real cutover blockers
#             and trip `--gate` unless baselined (see CORPUS_BASELINE).
#   MODE    — a harness artifact, NOT a language gap: relative/dir-index import
#             `fs_read_file failed` (ENOENT). (In `debug` mode also: codegen
#             `undefined variable` for unlinked builtin bodies, and `no functions
#             found` for a missing fixed entry name.)
# Host checker prelude intrinsics (src/checker/prelude.mbt `prelude_names`). The
# host injects these into the check env; the gate's linked check path does not
# load the prelude, so files using them get a spurious `unknown name`. This is a
# harness/env-init artifact, not a language gap. Keep in sync with prelude.mbt:
# the bare/`__`-prefixed names plus the full `Ns::method` set from prelude_names().
PRELUDE_INTRINSICS="add sub mul div eq lt not and or assert assert_true to_string iter_require iter_length iter_get assert_eq where __add __sub __mul __div __mod __eq __lt __neg __not __or __and __index __len __slice __to_string __bit_and __bit_or __bit_xor __lshift __rshift __assert __assert_eq String::iter_length String::iter_get Map::iter_length Map::iter_get Array::map Array::fold Array::filter Array::foreach Array::concat Array::reverse Array::any Array::all Array::find Array::sort Array::contains Array::join Map::get_or Map::map Map::filter"

is_prelude_intrinsic() {
  # $1 = bare name extracted from `unknown name: <name>`
  case " $PRELUDE_INTRINSICS " in *" $1 "*) return 0 ;; esac
  return 1
}

classify_err() {
  case "$1" in
    # Import resolution is a harness concern (relative/dir-index path forms), not
    # a language-expressiveness gap.
    *"fs_read_file failed"*) echo "MODE" ;;
    # debug-mode-only artifacts (codegen builtin bodies not linked / fixed entry
    # name missing). In `check` mode these do not occur.
    *"undefined variable"*|*"no functions found"*) echo "MODE" ;;
    # Host-prelude intrinsic not loaded by the gate's check env → harness.
    *"unknown name: "*)
      local nm="${1##*unknown name: }"
      nm="${nm%% *}"
      if is_prelude_intrinsic "$nm"; then echo "MODE"; else echo "REAL"; fi
      ;;
    # Everything else under `check` mode is a genuine selfhost checker/parser gap:
    # parse errors, type mismatches, genuine unknown names.
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
    bash "$RUNNER" --invoke cli_main "$SELFHOST_WASM" "$f" "$OUT_WASM_REL" "$ENTRY" "$COMPILE_MODE" \
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
echo "  mode: $COMPILE_MODE   files: ${#FILES[@]}   pass: $PASS   fail: $FAIL   (timeouts: $TIMEOUTS)"
echo "  REAL gaps (gate-tripping): $REAL"
echo "  MODE artifacts (import resolution / debug-codegen — not gaps): $MODE"
echo "  full results: $SUMMARY_TSV"
echo "================================================================"
if [ "$REAL" -gt 0 ]; then
  echo "  REAL gaps:"
  awk -F '\t' '$2 ~ /^fail\([0-9]+\)$/ && $3 == "REAL" { print $1 "\t" $4 }' "$SUMMARY_TSV" |
    sed 's/^/    - /'
fi

# Current REAL-failing set (genuine selfhost checker/parser gaps).
real_set="$(awk -F '\t' '$2 ~ /^fail\([0-9]+\)$/ && $3 == "REAL" { print $1 }' "$SUMMARY_TSV" | sort -u)"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
  {
    echo "# Selfhost corpus REAL-gap baseline (scripts/test_selfhost_corpus_gate.sh)."
    echo "# Files the selfhost compiler cannot yet \`check\` that the host accepts."
    echo "# Regenerate: scripts/test_selfhost_corpus_gate.sh --update-baseline"
    printf '%s\n' "$real_set" | grep -v '^$'
  } > "$BASELINE"
  echo "[corpus] baseline updated: $BASELINE ($(printf '%s\n' "$real_set" | grep -vc '^$') REAL files)"
fi

if [ "$GATE" -eq 1 ]; then
  baseline_set=""
  [ -f "$BASELINE" ] && baseline_set="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE" | sort -u)"
  new_real="$(comm -23 <(printf '%s\n' "$real_set" | grep -v '^$') <(printf '%s\n' "$baseline_set" | grep -v '^$'))"
  fixed="$(comm -13 <(printf '%s\n' "$real_set" | grep -v '^$') <(printf '%s\n' "$baseline_set" | grep -v '^$'))"
  gate_fail=0
  if [ -n "$new_real" ]; then
    echo ""
    echo "  REGRESSION — new REAL gap(s) not in baseline ($BASELINE):"
    printf '%s\n' "$new_real" | sed 's/^/    + /'
    gate_fail=1
  fi
  if [ -n "$fixed" ]; then
    echo ""
    echo "  BASELINE STALE — these now pass; remove from baseline (--update-baseline):"
    printf '%s\n' "$fixed" | sed 's/^/    - /'
    gate_fail=1
  fi
  if [ "$gate_fail" -eq 1 ]; then exit 1; fi
  echo "  --gate OK: REAL-failing set matches baseline ($(printf '%s\n' "$baseline_set" | grep -vc '^$') known gaps)"
fi
exit 0
