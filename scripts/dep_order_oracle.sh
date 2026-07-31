#!/usr/bin/env bash
# #906 Phase 0: dependency-visit-order oracle.
#
# The import-DAG typecheck walk visits each module's dependencies in
# DECLARATION order today. Phase 2 hands ready modules to workers, at which
# point the visit order becomes whatever the scheduler picks. The property
# that has to hold BEFORE any of that is built is:
#
#   the order dependencies are visited cannot change the output.
#
# This script tests exactly that, with no real parallelism: it compiles the
# same input several times with different VIBE_DEP_ORDER_SEED values (each
# seed permutes every node's dep visit order deterministically -- see
# set_dep_order_seed in runtime/typecheck_fs.vibe) and asserts the emitted
# wasm is byte-identical every time.
#
# Each run gets its OWN cold VIBE_BUILD_CACHE_DIR: a warm persistent cache
# would let later runs skip the very typecheck walk being permuted, so a
# shared cache could make this pass vacuously.
#
# Usage:
#   bash scripts/dep_order_oracle.sh <stage2.wasm> [input.vibe] [entry]
#
# Env:
#   VIBE_DEP_ORDER_SEEDS   space-separated seeds (default "0 1 2 7 4242")
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${1:-}"
INPUT="${2:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
ENTRY="${3:-__no_entry__}"
SEEDS="${VIBE_DEP_ORDER_SEEDS:-0 1 2 7 4242}"

if [ -z "$STAGE2" ] || [ ! -s "$STAGE2" ]; then
  echo "[dep-order-oracle] usage: bash scripts/dep_order_oracle.sh <stage2.wasm> [input.vibe] [entry]" >&2
  exit 2
fi
if [ ! -f "$INPUT" ]; then
  echo "[dep-order-oracle] FAIL: input not found: $INPUT" >&2
  exit 2
fi

# Vacuity guard. This oracle's whole value is that a non-zero seed actually
# reaches dep_visit_order; if the seed is never read, every run compiles
# identically for the boring reason and the oracle reports success while
# testing nothing. That is not hypothetical -- it happened during Phase 0:
# generate_bundle.sh failed its typecheck, the #979 sticky-failure guard kept
# the PREVIOUS adapter, and the resulting stage2 simply had no
# VIBE_DEP_ORDER_SEED read in it. Five seeds "passed" against a compiler that
# could not see them. The env var name is a literal in the adapter, so its
# absence from the binary is a direct, cheap test for that whole class.
if ! grep -qa "VIBE_DEP_ORDER_SEED" "$STAGE2"; then
  echo "[dep-order-oracle] FAIL: $STAGE2 contains no VIBE_DEP_ORDER_SEED wiring." >&2
  echo "[dep-order-oracle] The seed cannot reach dep_visit_order, so this run would pass vacuously." >&2
  echo "[dep-order-oracle] Rebuild after a SUCCESSFUL generate_bundle.sh (check its exit code -- it" >&2
  echo "[dep-order-oracle] keeps the old adapter on failure) and re-run." >&2
  exit 2
fi

# Second vacuity question, and the reason it is worth asking again: since
# #1239 step 4(D) the seed permutes the order WITHIN A RANK of the schedule,
# not a node's dependency visit order -- the walk no longer descends, it steps
# a wave at a time (ensure_fingerprint_fs_impl, runtime/typecheck_fs.vibe).
# A permutation of a one-element wave is the identity, so on a graph that
# happened to be a single chain this oracle would again pass for the boring
# reason. It is not: on this repo's own codegen_lexer_test.vibe graph, 150 of
# 166 modules (90%) sit in a rank with at least one sibling, and the largest
# rank holds 19. The seed therefore reorders most of the schedule, which is
# precisely the choice a parallel coordinator makes differently run to run.

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

reference=""
reference_seed=""
status=0

for seed in $SEEDS; do
  out="$work/out_$seed.wasm"
  cache="$work/cache_$seed"
  rm -rf "$cache"; mkdir -p "$cache"
  rm -f "$out" "$out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_BUILD_CACHE_DIR="$cache" VIBE_DEP_ORDER_SEED="$seed" \
    timeout 600 bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$STAGE2" "$INPUT" "$out" "$ENTRY" >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    echo "[dep-order-oracle] FAIL: seed=$seed did not compile $INPUT" >&2
    cat "$out.diag" 2>/dev/null >&2 || true
    exit 1
  fi
  size="$(wc -c < "$out")"
  if [ -z "$reference" ]; then
    reference="$out"
    reference_seed="$seed"
    echo "[dep-order-oracle] seed=$seed $size B (reference)"
  elif cmp -s "$reference" "$out"; then
    echo "[dep-order-oracle] seed=$seed $size B ok"
  else
    echo "[dep-order-oracle] FAIL: seed=$seed output differs from seed=$reference_seed ($size B vs $(wc -c < "$reference") B)" >&2
    echo "[dep-order-oracle] dependency visit order changed the compiled output -- the import-DAG walk is order-DEPENDENT, which blocks #906 Phase 2 (parallel frontend). Reproduce with VIBE_DEP_ORDER_SEED=$seed." >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  exit 1
fi
echo "[dep-order-oracle] output invariant across seeds: $SEEDS"
