#!/usr/bin/env bash
# Multi-workload coverage merge for the selfhost compiler (#cov).
#
# A single workload under-covers the compiler: self-compiling exercises the
# parser/checker/codegen but never the printer (only `normalize` hits it) or the
# Perceus RC path (only VIBE_RC=1 hits it). This builds ONE instrumented compiler
# and runs it under several workloads, then UNION-merges the per-run hit bitmaps
# (same binary => same function/branch ids) into one combined report.
#
#   scripts/coverage_merge.sh                 # default: compile + normalize + rc
#   scripts/coverage_merge.sh extra1.vibe ... # also FS-compile each extra file
#   VIBE_COV_SHOW_BRANCH_GAPS=1 scripts/coverage_merge.sh
#
# Output (_build/coverage/selfhost-merge/):
#   compiler_cov.wasm        instrumented compiler
#   <workload>.json          per-workload raw report
#   merged.json              union report {fn, branch, per_fn, top_gaps, workloads}
set -euo pipefail
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SEED="${VIBE_COV_SEED:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
FLAT_ABS="$ROOT_DIR/lib/@vibe/compiler/_cli_adapter_module_source.vibe"
OUT_DIR="${VIBE_COV_DIR:-$ROOT_DIR/_build/coverage/selfhost-merge}"
COMPILER_COV="$OUT_DIR/compiler_cov.wasm"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

[ -s "$SEED" ] || { echo "coverage_selfhost_merge: seed not found: $SEED" >&2; exit 1; }
[ -s "$FLAT_ABS" ] || { echo "coverage_selfhost_merge: flat compiler source not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

rel() { realpath --relative-to="$ROOT_DIR" "$1"; }
FLAT="$(rel "$FLAT_ABS")"
COMPILER_COV_REL="$(rel "$COMPILER_COV")"

# 1. Build the instrumented compiler once.
echo "[cov-merge] building instrumented compiler ..." >&2
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$SEED" "$FLAT" "$COMPILER_COV_REL" cli_main
[ -s "$COMPILER_COV" ] || { echo "coverage_selfhost_merge: instrumented compiler not produced (seed lacks VIBE_COVERAGE?)" >&2; exit 1; }

reports=()

# run_workload <name> <env-assignments...> -- <runner-args...>
# Runs the instrumented compiler with VIBE_COV_OUT+VIBE_COV_RAW and records the
# per-workload report path.
run_workload() {
  local name="$1"; shift
  local out="$OUT_DIR/$name.json"
  echo "[cov-merge] workload: $name" >&2
  if VIBE_COV_OUT="$out" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT_DIR" "$@" >/dev/null 2>&1 && [ -s "$out" ]; then
    reports+=("$out")
  else
    echo "[cov-merge] WARN: workload '$name' produced no report (skipped)" >&2
  fi
}

# A small but construct-rich sample to drive the printer via `normalize`.
sample="$OUT_DIR/sample.vibe"
cat > "$sample" <<'EOF'
enum Shape { Circle(Int); Rect(Int, Int); Dot }
let area: (Shape) -> Int = (s) -> {
  match s {
    Circle(r) => r * r * 3,
    Rect(w, h) => w * h,
    Dot => 0
  }
}
let describe: (Int) -> String = (n) -> {
  if n > 100 { "big" } else if n > 0 { "small" } else { "none" }
}
export let run: () -> Int = () -> {
  let xs = [area(Circle(2)), area(Rect(3, 4)), area(Dot)]
  let mut total = 0
  for x in xs { total = total + x }
  total
}
export { run }
EOF
sample_rel="$(rel "$sample")"

# Workload A: self-compile the flat compiler source (parser/checker/codegen).
run_workload compile \
  env VIBE_IMPORT_ABI=raw \
  VIBE_INTERNAL_TRUSTED_SOURCE=1 bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$FLAT" "$OUT_DIR/out_compile.wasm" cli_main

# Workload B: normalize the sample (exercises the AST printer: print_expr/_stmt).
run_workload normalize \
  env VIBE_NORMALIZE=1 \
  bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$sample_rel" "$OUT_DIR/out_normalize.vibe"

# Workload C: compile the self-contained sample under VIBE_RC=1 (exercises the
# Perceus RC codegen: pc_count/pc_emit/elaborate_rw...). Uses the single-source
# (non-FS) path, which honors VIBE_RC; RC-self-compiling the whole 4.8MB flat
# source is too heavy and traps, so a small program is the right driver here.
run_workload rc \
  env VIBE_RC=1 VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$sample_rel" "$OUT_DIR/out_rc.wasm" run

# Extra workloads: FS-compile each path passed on the command line.
for extra in "$@"; do
  ename="file_$(echo "$extra" | tr '/.' '__')"
  run_workload "$ename" \
    env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$extra" "$OUT_DIR/out_$ename.wasm" _start
done

if [ "${#reports[@]}" -eq 0 ]; then
  echo "coverage_selfhost_merge: no workloads succeeded" >&2; exit 1
fi

# 2. Union-merge the raw bitmaps and report.
python3 - "$OUT_DIR/merged.json" "${VIBE_COV_SHOW_BRANCH_GAPS:-0}" "${reports[@]}" <<'PY'
import json, sys
merged_path = sys.argv[1]
show_gaps = sys.argv[2] == "1"
paths = sys.argv[3:]

fn_names = None
br_owners = None
fn_hits = None
br_hits = None
per_workload = []

for p in paths:
    r = json.load(open(p))
    raw = r.get("raw")
    if not raw:
        print(f"[cov-merge] WARN: {p} has no raw bitmap (VIBE_COV_RAW?), skipped", file=sys.stderr)
        continue
    fb = raw["fn_bitmap"]
    bb = raw.get("branch_bitmap", [])
    if fn_hits is None:
        fn_names = raw["fn_names"]
        br_owners = raw.get("branch_owners", [])
        fn_hits = [0] * len(fb)
        br_hits = [0] * len(bb)
    for i, v in enumerate(fb):
        if v:
            fn_hits[i] = 1
    for i, v in enumerate(bb):
        if v:
            br_hits[i] = 1
    name = p.rsplit("/", 1)[-1][:-5]
    per_workload.append({
        "workload": name,
        "fn_hit": sum(fb),
        "branch_hit": sum(bb),
    })

if fn_hits is None:
    print("[cov-merge] no raw reports to merge", file=sys.stderr)
    sys.exit(1)

fn_total = len(fn_hits)
fn_hit = sum(fn_hits)
br_total = len(br_hits)
br_hit = sum(br_hits)

# Per-function branch aggregation from merged branch hits.
per_fn = {}
for bid, owner in enumerate(br_owners):
    nm = fn_names[owner] if 0 <= owner < len(fn_names) else f"#{owner}"
    e = per_fn.setdefault(nm, {"total": 0, "hit": 0})
    e["total"] += 1
    e["hit"] += br_hits[bid]
gaps = sorted(
    ({"fn": nm, "taken": e["hit"], "total": e["total"]} for nm, e in per_fn.items() if e["hit"] < e["total"]),
    key=lambda g: g["total"] - g["taken"], reverse=True,
)
missed_fns = [fn_names[i] for i, v in enumerate(fn_hits) if not v]

merged = {
    "workloads": per_workload,
    "total": fn_total, "hit": fn_hit, "missed": fn_total - fn_hit,
    "rate": fn_hit / fn_total if fn_total else 0,
    "missed_fns": missed_fns,
    "branch": {
        "total": br_total, "hit": br_hit, "missed": br_total - br_hit,
        "rate": br_hit / br_total if br_total else 0,
        "per_fn": per_fn, "top_gaps": gaps[:50],
    },
}
json.dump(merged, open(merged_path, "w"), indent=2)

print("[cov-merge] per-workload (cumulative is the merge):")
for w in per_workload:
    print(f"  {w['workload']:12s} fn {w['fn_hit']:5d}  branch {w['branch_hit']:5d}")
fnp = f"{fn_hit/fn_total*100:.2f}%" if fn_total else "n/a"
brp = f"{br_hit/br_total*100:.2f}%" if br_total else "n/a"
print(f"[cov-merge] MERGED: functions {fn_hit}/{fn_total} ({fnp}), branches {br_hit}/{br_total} ({brp})")
if show_gaps:
    print("top functions with untaken branches (merged):")
    for g in gaps[:25]:
        print(f"  {g['fn']}: {g['taken']}/{g['total']} taken")
PY
echo "[cov-merge] merged report: $OUT_DIR/merged.json" >&2
