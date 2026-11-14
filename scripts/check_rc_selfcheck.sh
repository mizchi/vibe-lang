#!/usr/bin/env bash
# #3718: the RC plans of the selfhost compiler itself, checked against the
# linear ownership discipline. `vibe rc-validate` answers for one file at a
# time and cannot answer for the compiler: the flat selfhost source in one
# process exhausts the wasm32 heap. So stage2 compiles that source exactly as
# `scripts/generations.sh` compiles stage3, with VIBE_RC_SELFCHECK_OUT set:
# codegen then validates each top-level function's plan right after building
# it (perceus_selfcheck_plan) and the compile writes the report.
#
# The report's lines are `vibe rc-validate`'s. Like
# scripts/check_rc_validate_corpus.sh, this gate FAILS on a plan that releases
# a reference it does not hold, a borrowed parameter consumed without a dup, a
# consume mark on a non-consuming occurrence, or a heap value planned as
# scalar -- the use-after-free shapes. A leak line (the direction the planner
# accepts today, #705), a reference-cycle warning and a `not checked` line are
# counted and printed. A report with no `plans N of M` header, or N = 0, FAILS:
# it reads exactly like a clean one but says the check never ran.
#
# The compiling stage2 runs on the bump lane, which never frees, and one
# compile of the flat source leaves a few hundred MB of the wasm32 heap. So the
# plans are split over RC_SELFCHECK_SHARDS compiles (default 32;
# VIBE_RC_SELFCHECK_SHARD=k/N checks plans k, k+N, ...). Measured on the
# compiler at 13,364 plans, a 1/32 shard peaked between 3.94 and 4.27 GB of the
# 4.26 GB reservation, and two of 32 did not fit. So a shard that exhausts the
# heap is split in two (k/N into k/2N and (k+N)/2N) and both halves are run.
# The shards together must have checked every plan the compile built: a set
# that checked fewer FAILS the gate.
#
# A heap exhaustion can surface as `RuntimeError: unreachable` as well as
# `memory access out of bounds` (shard 16/32 did, measured), so both split.
# One plan can be too big to check inside the compile at all: its check alone
# needs more than the heap the compile leaves (check_call_expr, plan 4560 of
# 13,364, exhausts the heap in a shard of its own, and `vibe rc-validate --fn
# check_call_expr` checks it in a process of its own). Such a function is
# named in scripts/rc_selfcheck_exempt.txt (RC_SELFCHECK_EXEMPT_FILE
# overrides): its plan is reported `exempt NAME` instead of checked, and it
# counts toward the plans the shards cover. The list is a ratchet -- a name
# it lists that the compile never built is stale and FAILS the gate, and so
# does an `exempt` line for a name it does not list.
#
# Usage:
#   RC_SELFCHECK_STAGE2=<stage2.wasm> bash scripts/check_rc_selfcheck.sh [<flat source>]
#     (the flat source defaults to the stage2 generation's
#     cli_adapter_module_source.vibe)
#   bash scripts/check_rc_selfcheck.sh --report <report>...   # classify only (one per shard)
#
# RC_SELFCHECK_ENTRY names the compile's entry (default `cli_main`, the flat
# source's); the self-test compiles a fixture with `__no_entry__`.
# RC_SELFCHECK_MAX_SHARDS (default 1024) is the finest split allowed before a
# heap exhaustion fails the gate.
#
# `--report` reads a report written earlier. It is the seam
# scripts/check_rc_selfcheck_test.sh uses to show that a mutated report fails.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

EXEMPT_FILE="${RC_SELFCHECK_EXEMPT_FILE:-$ROOT_DIR/scripts/rc_selfcheck_exempt.txt}"
exempt_names() { [ -f "$EXEMPT_FILE" ] && grep -vE '^[[:space:]]*(#|$)' "$EXEMPT_FILE" || true; }

fatal_pattern=': (owned value released [0-9]+ more than held|borrowed parameter consumed without a dup|consume mark at offset -?[0-9]+ is not a consuming occurrence|heap value planned as scalar)$'

# classify <report>...: every report is one shard of the same compile.
classify() {
  local total=0 built="" report header n m
  : >"$CLASSIFY_BODY"
  for report in "$@"; do
    header="$(head -n 1 "$report")"
    case "$header" in
      "plans "*" of "*) n="${header#plans }"; n="${n%% of *}"; m="${header##* of }" ;;
      *)
        echo "[rc-selfcheck] FAIL: $report has no 'plans N of M' header -- the compile did not run the self-check" >&2
        return 1 ;;
    esac
    case "$n$m" in
      ''|*[!0-9]*) echo "[rc-selfcheck] FAIL: unreadable plan count: $header" >&2; return 1 ;;
    esac
    if [ "$n" -eq 0 ]; then
      echo "[rc-selfcheck] FAIL: a shard validated 0 plans -- an empty report is not a clean one" >&2
      return 1
    fi
    if [ -n "$built" ] && [ "$built" != "$m" ]; then
      echo "[rc-selfcheck] FAIL: the shards disagree on how many plans the compile built ($built vs $m)" >&2
      return 1
    fi
    built="$m"
    total=$((total + n))
    tail -n +2 "$report" >>"$CLASSIFY_BODY"
  done
  local exempt name
  exempt="$(grep -c '^exempt ' "$CLASSIFY_BODY" || true)"
  for name in $(grep '^exempt ' "$CLASSIFY_BODY" | cut -c8- | sort -u); do
    exempt_names | grep -qxF "$name" || {
      echo "[rc-selfcheck] FAIL: a report exempts $name, which $EXEMPT_FILE does not list" >&2
      return 1
    }
  done
  for name in $(exempt_names); do
    grep -qxF "exempt $name" "$CLASSIFY_BODY" || {
      echo "[rc-selfcheck] FAIL: $EXEMPT_FILE lists $name, but the compile built no plan of that name -- delete it from the list" >&2
      return 1
    }
  done
  if [ $((total + exempt)) -ne "$built" ]; then
    echo "[rc-selfcheck] FAIL: the shards checked $total (and exempted $exempt) of the $built plans the compile built" >&2
    return 1
  fi
  local fatal leaks cycles skips
  fatal="$(grep -cE "$fatal_pattern" "$CLASSIFY_BODY" || true)"
  leaks="$(grep -cE ': owned value not consumed( \([0-9]+ references\))?$' "$CLASSIFY_BODY" || true)"
  cycles="$(grep -c 'warning: reference cycle' "$CLASSIFY_BODY" || true)"
  skips="$(grep -c 'not checked: ' "$CLASSIFY_BODY" || true)"
  echo "[rc-selfcheck] plans=$total exempt=$exempt fatal=$fatal leaks=$leaks cycles=$cycles not-checked=$skips"
  if [ "$fatal" -gt 0 ]; then
    echo "[rc-selfcheck] FAIL: a compiler plan releases more than it holds, or a heap value it does not count:" >&2
    grep -E "$fatal_pattern" "$CLASSIFY_BODY" | head -50 >&2
    return 1
  fi
  echo "[rc-selfcheck] ok"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_rc_selfcheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CLASSIFY_BODY="$WORK/body.txt"

if [ "${1:-}" = "--report" ]; then
  shift
  [ "$#" -ge 1 ] || { echo "[rc-selfcheck] FAIL: --report needs at least one path" >&2; exit 2; }
  for r in "$@"; do
    [ -f "$r" ] || { echo "[rc-selfcheck] FAIL: no such report: $r" >&2; exit 2; }
  done
  classify "$@"
  exit $?
fi

# A gate must be told WHICH compiler (CLAUDE.md, "Which compiler answered?").
# shellcheck source=resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 rc-selfcheck "${RC_SELFCHECK_STAGE2:-}")" || exit 1
SOURCE="${1:-$(dirname "$STAGE2")/cli_adapter_module_source.vibe}"
[ -s "$SOURCE" ] || { echo "[rc-selfcheck] FAIL: no flat selfhost source at $SOURCE (pass it, or use a generation built by scripts/generations.sh)" >&2; exit 1; }

shards="${RC_SELFCHECK_SHARDS:-32}"
case "$shards" in ''|*[!0-9]*|0) echo "[rc-selfcheck] FAIL: RC_SELFCHECK_SHARDS must be a positive integer" >&2; exit 2 ;; esac
# The finest split a shard may be cut to before a heap exhaustion counts as a
# failure: past it, one plan alone does not fit, and that is a finding.
max_shards="${RC_SELFCHECK_MAX_SHARDS:-1024}"
reports=()
queue=()
k=0
while [ "$k" -lt "$shards" ]; do
  queue+=("$k/$shards")
  k=$((k + 1))
done
qi=0
while [ "$qi" -lt "${#queue[@]}" ]; do
  shard="${queue[$qi]}"
  qi=$((qi + 1))
  k="${shard%/*}"
  n="${shard#*/}"
  report="$WORK/report.$k.$n.txt"
  status=0
  # The flat source carries the internal Iterator-boundary imports only a
  # trusted source may (scripts/generations.sh exports the same). The
  # self-build is pinned to the bump lane, which builds no plan, so this
  # compiles the compiler on the RC lane -- the build of it that has plans --
  # with the measured wasm32 reservation scripts/test_cli_core.sh gives its
  # RC build, and the stack scripts/generations.sh gives a stage compile.
  VIBE_RC=1 VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_WASM_PRE_GROW_PAGES="${RC_SELFCHECK_PRE_GROW_PAGES:-65000}" \
    VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=131072}" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SKIP_RUN_INIT=1 \
    VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE=1 VIBE_RC_SELFCHECK_OUT="$report" VIBE_RC_SELFCHECK_SHARD="$shard" \
    VIBE_RC_SELFCHECK_EXEMPT="$(exempt_names | paste -sd, -)" \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$STAGE2" "$SOURCE" "$WORK/out.wasm" "${RC_SELFCHECK_ENTRY:-cli_main}" >"$WORK/log.txt" 2>&1 || status=$?
  if [ "$status" != 0 ] || [ ! -s "$WORK/out.wasm" ]; then
    # The compile itself fits (the plans are built either way); what can
    # exhaust the heap is the checking. Split the shard and try both halves.
    if grep -qE 'memory access out of bounds|RuntimeError: unreachable' "$WORK/log.txt" && [ $((n * 2)) -le "$max_shards" ]; then
      echo "[rc-selfcheck] shard $shard exhausted the heap; splitting into $k/$((n * 2)) and $((k + n))/$((n * 2))"
      queue+=("$k/$((n * 2))" "$((k + n))/$((n * 2))")
      rm -f "$WORK/out.wasm" "$WORK/out.wasm.diag" "$report"
      continue
    fi
    echo "[rc-selfcheck] FAIL: stage2 did not compile $SOURCE for shard $shard (exit $status)" >&2
    echo "[rc-selfcheck] (VIBE_RC_SELFCHECK_LIST=1 with VIBE_RC_SELFCHECK_SHARD=$shard names the shard's plans; a plan too big to check inside the compile goes in $EXEMPT_FILE)" >&2
    grep -v '^ *at ' "$WORK/log.txt" | tail -20 >&2
    [ -f "$WORK/out.wasm.diag" ] && head -20 "$WORK/out.wasm.diag" >&2
    exit 1
  fi
  [ -f "$report" ] || { echo "[rc-selfcheck] FAIL: the compile wrote no report -- this stage2 predates the self-check" >&2; exit 1; }
  reports+=("$report")
  rm -f "$WORK/out.wasm" "$WORK/out.wasm.diag"
done
classify "${reports[@]}"
