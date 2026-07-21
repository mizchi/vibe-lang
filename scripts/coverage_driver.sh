#!/usr/bin/env bash
# Driver coverage for the selfhost compiler (#cov): append scripts/coverage/
# cov_driver.vibe to the flat module source, compile it under coverage with
# entry `cov_driver_main`, run it, and union the executed branches into the
# corpus acc.json by (fn_name, local_branch_index). The driver calls the
# compiler's type/trait/env functions directly with edge-case inputs the
# black-box corpus never triggers (type_to_string of every Type variant, all
# unify/types_equal pairs, a trait-bearing TypeEnv). This is the test-execution
# coverage lever for the deep checker functions, bypassing the cyclic re-export
# blocker that stops the in-tree *_test.vibe from FS-compiling.
#
#   scripts/coverage_driver.sh    # merges into _build/coverage/selfhost-corpus/acc.json
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SEED="${VIBE_COV_SEED:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
FLAT="lib/@vibe/compiler/_cli_adapter_module_source.vibe"
DRIVER="scripts/coverage/cov_driver.vibe"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
ACC="$ROOT_DIR/_build/coverage/selfhost-corpus/acc.json"
OUT="$ROOT_DIR/_build/coverage/selfhost-driver"
rm -rf "$OUT"; mkdir -p "$OUT"
[ -s "$ACC" ] || { echo "driver: corpus acc not found; run coverage_corpus.sh first" >&2; exit 1; }

cat "$FLAT" "$DRIVER" > "$OUT/driver_src.vibe"
# The seed compiler occasionally OOMs on this huge (29k-line) source under
# coverage instrumentation; retry a few times (non-deterministic heap pressure).
ok=0
for t in 1 2 3 4 5 6 7 8; do
  rm -f "$OUT/driver.wasm"
  VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$SEED" "$OUT/driver_src.vibe" "$OUT/driver.wasm" cov_driver_main >/dev/null 2>&1 || true
  [ -s "$OUT/driver.wasm" ] && { ok=1; break; }
done
[ "$ok" = 1 ] || { echo "driver: compile failed after retries" >&2; exit 1; }

VIBE_COV_OUT="$OUT/cov.json" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$RUNNER" "$OUT/driver.wasm" >/dev/null 2>&1 || true
[ -s "$OUT/cov.json" ] || { echo "driver: run produced no coverage" >&2; exit 1; }

python3 - "$ACC" "$OUT/cov.json" <<'PY'
import json, sys, os
from collections import defaultdict
acc = json.load(open(sys.argv[1]))
fnC, owC, brC = acc["fn_names"], acc["br_owners"], acc["br"]
localC = defaultdict(list)
for gid, o in enumerate(owC):
    nm = fnC[o] if 0 <= o < len(fnC) else None
    if nm is not None: localC[nm].append(gid)
base = sum(brC)
raw = json.load(open(sys.argv[2]))["raw"]
nT, owT, bmT = raw["fn_names"], raw["branch_owners"], raw["branch_bitmap"]
seen = defaultdict(int)
for i, o in enumerate(owT):
    nm = nT[o] if 0 <= o < len(nT) else None
    li = seen[nm]; seen[nm] += 1
    if nm is None or not bmT[i]: continue
    ids = localC.get(nm)
    if ids and li < len(ids): brC[ids[li]] = 1
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as fh: json.dump(acc, fh)
os.replace(tmp, sys.argv[1])
tot, hit = len(brC), sum(brC)
print(f"[driver] merged into corpus: {base} -> {hit}/{tot} ({hit/tot*100:.2f}%)  (+{hit-base})")
PY
