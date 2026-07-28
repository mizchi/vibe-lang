#!/usr/bin/env bash
# Test-execution coverage for the selfhost compiler (#cov, #613 unblocked this):
# the compiler's own *_test.vibe files call internal functions (type_to_string,
# unify, types_equal, serialize_type, ...) directly in their assertions. Black-box
# compilation of arbitrary programs never EXECUTES those functions (it only emits
# calls to them), so they stay dark. Here we COMPILE each compiler test UNDER
# coverage (instrumented output) and RUN it, then union the executed branches into
# the black-box corpus coverage, keyed by (fn_name, local_branch_index) so the two
# differently-compiled binaries merge correctly.
#
#   scripts/coverage_testexec.sh
#
# Output (_build/coverage/selfhost-testexec/): merged.json with the unified rate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SEED="$ROOT_DIR/bootstrap/seed/compiler.wasm"
FLAT="lib/@vibe/compiler/_cli_adapter_module_source.vibe"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
OUT_DIR="$ROOT_DIR/_build/coverage/selfhost-testexec"
CORPUS_ACC="$ROOT_DIR/_build/coverage/selfhost-corpus/acc.json"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR/bins"
rel() { realpath --relative-to="$ROOT_DIR" "$1"; }

[ -s "$CORPUS_ACC" ] || { echo "testexec: corpus acc not found; run coverage_corpus.sh first" >&2; exit 1; }

# Per-test: compile under coverage (instrument output) + run, dump raw bitmap.
i=0; comp_ok=0; run_ok=0
: > "$OUT_DIR/runs.txt"
for f in lib/@vibe/compiler/*_test.vibe; do
  i=$((i+1))
  base="$(basename "$f" .vibe)"
  bin="$OUT_DIR/bins/$base.wasm"
  cov="$OUT_DIR/bins/$base.json"
  # entry: tests use the sentinel (compiler emits a test-running _start)
  if VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash "$RUNNER" --invoke cli_main "$SEED" "$f" "$bin" "__no_entry__" >/dev/null 2>&1 && [ -s "$bin" ]; then
    comp_ok=$((comp_ok+1))
    if VIBE_COV_OUT="$cov" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
        bash "$RUNNER" "$bin" >/dev/null 2>&1 && [ -s "$cov" ]; then
      run_ok=$((run_ok+1)); echo "$cov" >> "$OUT_DIR/runs.txt"
    else
      echo "run-fail $f" >> "$OUT_DIR/fails.txt"
    fi
  else
    echo "compile-fail $f" >> "$OUT_DIR/fails.txt"
  fi
  if [ $((i % 25)) -eq 0 ]; then echo "[testexec] $i tests: compile_ok=$comp_ok run_ok=$run_ok" >&2; fi
done
echo "[testexec] done: $i tests, compile_ok=$comp_ok run_ok=$run_ok" >&2

# Merge: union each test binary's executed branches into the corpus coverage,
# keyed by (fn_name, local_branch_index). Report the unified branch rate.
python3 - "$CORPUS_ACC" "$OUT_DIR/runs.txt" "$OUT_DIR/merged.json" <<'PY'
import json, sys
corpus = json.load(open(sys.argv[1]))
fn_names_C = corpus["fn_names"]; br_owners_C = corpus["br_owners"]; br_C = corpus["br"][:]
# local index map for corpus: fn_name -> [global ids in id order]
from collections import defaultdict
local_C = defaultdict(list)
for gid, ow in enumerate(br_owners_C):
    nm = fn_names_C[ow] if 0 <= ow < len(fn_names_C) else None
    if nm is not None:
        local_C[nm].append(gid)

base_hit = sum(br_C)
tests_merged = 0
runs = [l.strip() for l in open(sys.argv[2]) if l.strip()]
for rp in runs:
    try:
        raw = json.load(open(rp))["raw"]
    except Exception:
        continue
    names_T = raw["fn_names"]; owners_T = raw["branch_owners"]; bm_T = raw["branch_bitmap"]
    # local index within each fn for the test binary (id order)
    seen = defaultdict(int)
    for i, ow in enumerate(owners_T):
        nm = names_T[ow] if 0 <= ow < len(names_T) else None
        li = seen[nm]; seen[nm] += 1
        if nm is None or not bm_T[i]:
            continue
        ids = local_C.get(nm)
        if ids is not None and li < len(ids):
            br_C[ids[li]] = 1
    tests_merged += 1

tot = len(br_C); hit = sum(br_C)
out = {"branch_total": tot, "corpus_hit": base_hit, "unified_hit": hit,
       "corpus_rate": base_hit/tot, "unified_rate": hit/tot, "tests_merged": tests_merged,
       "added_by_tests": hit-base_hit}
json.dump(out, open(sys.argv[3], "w"), indent=2)
print(f"[testexec] corpus (black-box):  {base_hit}/{tot} ({base_hit/tot*100:.2f}%)")
print(f"[testexec] + test execution:    {hit}/{tot} ({hit/tot*100:.2f}%)  (+{hit-base_hit} from {tests_merged} tests)")
PY
echo "[testexec] report: $OUT_DIR/merged.json" >&2
