#!/usr/bin/env bash
# Corpus coverage for the selfhost compiler (#cov): build ONE instrumented
# compiler and run it over a large corpus of .vibe programs (each COMPILE
# exercises parser/checker/codegen; each NORMALIZE exercises the printer),
# union-merging every run's hit bitmap into one report. Complements
# coverage_merge.sh (which is the small fixed compile/normalize/rc set).
#
#   scripts/coverage_corpus.sh [dir-or-file ...]   # default: examples fixtures
#   VIBE_COV_MAX=200 scripts/coverage_corpus.sh    # cap number of files
#   VIBE_COV_SHOW_BRANCH_GAPS=1 ...                         # list remaining branch gaps
#
# Output (_build/coverage/selfhost-corpus/): acc.json (running union), fails.txt.
set -euo pipefail
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SEED="${VIBE_COV_SEED:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
FLAT_ABS="$ROOT_DIR/lib/@vibe/compiler/_cli_adapter_module_source.vibe"
OUT_DIR="${VIBE_COV_DIR:-$ROOT_DIR/_build/coverage/selfhost-corpus}"
COMPILER_COV="$OUT_DIR/compiler_cov.wasm"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
# Instrumenting the ~5MB flat compiler source recurses deep enough to exhaust
# node's DEFAULT stack, and the host reports that as
# `[vibe] stack overflow: expression too deeply nested` -- which reads like the
# SOURCE is at fault rather than the runner. Every other lane that feeds the
# same flat source through node already raises this (generate_bundle.sh,
# generations.sh); this one did not, so `[corpus] building instrumented
# compiler ...` was the last line it ever printed. Same 131072 they use.
export VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --experimental-wasm-inlining --stack-size=131072}"
ACC="$OUT_DIR/acc.json"
RUN_JSON="$OUT_DIR/run.json"
FAILS="$OUT_DIR/fails.txt"
MAX="${VIBE_COV_MAX:-100000}"

# The flat adapter is generated from compiler sources. Keep this corpus entry
# validation-only and portable on stock BSD/macOS: require every fixed input,
# synchronously materialize the discovered source list, then compare mtimes.
# Any missing/stale input or producer failure is actionable and fail-closed.
coverage_require_fresh_flat() {
  local flat_abs="${1:-$FLAT_ABS}"
  local input list_file sorted_file
  local required=(
    bootstrap/seed/compiler.wasm
    lib/@vibe/compiler/compiler_sources_manifest.tsv
    scripts/generate_bundle.sh
    scripts/ensure_generated.sh
  )
  [ -s "$flat_abs" ] || {
    echo "corpus: generated flat compiler source missing; run: bash scripts/ensure_generated.sh" >&2
    return 1
  }
  for input in "${required[@]}"; do
    [ -s "$input" ] || {
      echo "corpus: required freshness input missing or empty: $input; run: bash scripts/ensure_generated.sh" >&2
      return 1
    }
  done
  list_file="$(mktemp "${TMPDIR:-/tmp}/vibe-cov-inputs.XXXXXX")" || return 1
  sorted_file="$list_file.sorted"
  if ! find lib/@vibe lib/@vibex -type f \
      \( -name '*.vibe' -o -name '*.vpkg' \) \
      ! -path '*/tests/*' ! -name '*_test.vibe' ! -name '*_bench.vibe' \
      ! -name 'compiler_sources_bundle.vibe' \
      ! -name 'cli_adapter_bundle.vibe' \
      ! -name 'selfbuild_runtime_entry_bundle.vibe' \
      ! -name '_cli_adapter_module_source.vibe' \
      ! -name 'codegen_fingerprint.vibe' >"$list_file"; then
    echo "corpus: failed to enumerate freshness inputs; run: bash scripts/ensure_generated.sh" >&2
    rm -f "$list_file" "$sorted_file"
    return 1
  fi
  if ! { printf '%s\n' "${required[@]}"; cat "$list_file"; } | LC_ALL=C sort >"$sorted_file"; then
    echo "corpus: failed to sort freshness inputs; run: bash scripts/ensure_generated.sh" >&2
    rm -f "$list_file" "$sorted_file"
    return 1
  fi
  rm -f "$list_file"
  while IFS= read -r input; do
    [ -s "$input" ] || {
      echo "corpus: required freshness input missing or empty: $input; run: bash scripts/ensure_generated.sh" >&2
      rm -f "$sorted_file"
      return 1
    }
    if [ "$input" -nt "$flat_abs" ]; then
      echo "corpus: generated flat compiler source is stale after $input; run: bash scripts/ensure_generated.sh" >&2
      rm -f "$sorted_file"
      return 1
    fi
  done <"$sorted_file"
  rm -f "$sorted_file"
}

# BSD/macOS realpath has no GNU --relative-to. Python's relpath is portable and
# the containment check keeps every wasm-host path inside the preopened root.
rel() {
  python3 - "$ROOT_DIR" "$1" <<'PY'
import os, sys
root = os.path.realpath(sys.argv[1])
path = os.path.realpath(sys.argv[2])
try:
    inside = os.path.commonpath([root, path]) == root
except ValueError:
    inside = False
if not inside:
    raise SystemExit(f"corpus: path escapes repository root: {sys.argv[2]}")
print(os.path.relpath(path, root))
PY
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

[ -s "$SEED" ] || { echo "corpus: seed not found" >&2; exit 1; }
coverage_require_fresh_flat
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"; : > "$FAILS"
FLAT="$(rel "$FLAT_ABS")"

echo "[corpus] building instrumented compiler ..." >&2
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$SEED" "$FLAT" "$(rel "$COMPILER_COV")" cli_main
[ -s "$COMPILER_COV" ] || { echo "corpus: instrumented compiler not produced" >&2; exit 1; }
# Checkout-local coverage helper sources follow current package contracts. Use
# the just-built current compiler rather than allowing their wrappers to fall
# back to the potentially older committed seed.
export VIBE_COVERAGE_ACC_TOOL_COMPILER="$COMPILER_COV"

# accumulate one workload run (env... -- runner args); merge via
# scripts/coverage_acc_tool.vibex (OR RUN_JSON's raw bitmap into ACC,
# creating ACC on first call -- see that file's header comment).
acc_run() {
  rm -f "$RUN_JSON"
  VIBE_COV_OUT="$RUN_JSON" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT_DIR" "$@" >/dev/null 2>&1 || true
  [ -s "$RUN_JSON" ] && bash scripts/coverage_acc_tool_run.sh merge "$ACC" "$RUN_JSON" || return 1
}

# Base: self-compile (compile) + flat self-compile under RC are heavy; include
# the plain self-compile as the backbone, then the corpus broadens it.
echo "[corpus] base: self-compile" >&2
acc_run env VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_IMPORT_ABI=raw bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$FLAT" "$OUT_DIR/o.wasm" cli_main || true

# RC-stress: small heap-heavy programs RC-compiled (VIBE_RC=1) to exercise the
# Perceus dup/drop/alias codegen (pc_count/pc_emit/elaborate_rw...), which a
# plain bump-mode compile never reaches. These few programs reliably cover the
# Perceus branches that the bulk corpus (bump mode) leaves dark.
mkdir -p "$OUT_DIR/rcprog"
cat > "$OUT_DIR/rcprog/tree.vibe" <<'EOF'
enum Tree { Leaf(Int); Node(Tree, Tree) }
let sum: (Tree) -> Int = (t) -> { match t { Leaf(n) => n, Node(l, r) => sum(l) + sum(r) } }
let dup: (Tree) -> Tree = (t) -> { Node(t, t) }
export let main: () -> Int = () -> {
  let t = Node(Leaf(1), Node(Leaf(2), Leaf(3)))
  sum(dup(t)) + sum(t)
}
EOF
cat > "$OUT_DIR/rcprog/closure.vibe" <<'EOF'
export let main: () -> Int = () -> {
  let pairs = [(1, "a"), (2, "b"), (3, "c")]
  let mut acc = 0
  for p in pairs { let (n, s) = p; acc = acc + n + String::length(s) }
  let f = (x: Int) -> Int { x + acc }
  let g = (x: Int) -> Int { f(x) + f(x) }
  g(10)
}
EOF
cat > "$OUT_DIR/rcprog/alias.vibe" <<'EOF'
enum Opt { N; S(Int) }
let unwrap: (Opt, Int) -> Int = (o, d) -> { match o { N => d, S(x) => x } }
export let main: () -> Int = () -> {
  let xs = [S(1), N, S(3)]
  let mut t = 0
  for o in xs { t = t + unwrap(o, 0) }
  let ys = xs
  t + unwrap(Array::get(ys, 0), 9)
}
EOF
for rp in tree closure alias; do
  echo "[corpus] rc-stress: $rp" >&2
  acc_run env VIBE_RC=1 VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$(rel "$OUT_DIR/rcprog/$rp.vibe")" "$OUT_DIR/o.wasm" main || true
done

# Loader / persistent-cache orchestration (#cov): the cache read+manifest branches
# (parse_persistent_*_cache, matches_cached_file_spec, scan_header_*, manifest header
# parse) are NEVER reached by a plain one-shot compile of an examples/fixtures file —
# they only fire when (a) a project carries a `compiler_sources_manifest.tsv` (only the
# compiler tree does), and (b) a prior run already wrote the persistent cache so the
# next run takes the read path. We drive both: compile a manifest-rooted entry and a
# multi-import example repeatedly while selectively invalidating individual cache files
# between runs so each cache-state branch (groups-hit / list-read / manifest-read /
# fingerprint-miss) is taken at least once. Cache files live in ./_build/vibe_selfhost_*.
cache_clear() { rm -f _build/vibe_selfhost_* 2>/dev/null || true; }
fs_compile_run() { # label entry_path entry_name
  acc_run env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$(rel "$2")" "$OUT_DIR/o.wasm" "$3" || true
}
ORCH_ENTRIES=(
  "lib/@vibe/compiler/cli_adapter.vibe:cli_main"
  "examples/module_import.vibe:main"
  "examples/module_types_import.vibe:main"
)
for spec in "${ORCH_ENTRIES[@]}"; do
  ep="${spec%%:*}"; en="${spec##*:}"
  [ -f "$ep" ] || continue
  echo "[corpus] cache-orch: $ep ($en)" >&2
  cache_clear
  fs_compile_run cold "$ep" "$en"                                    # cold: writes caches
  fs_compile_run warm "$ep" "$en"                                    # warm: groups-cache hit
  rm -f _build/vibe_selfhost_source_groups_* 2>/dev/null || true     # force source-list read path
  fs_compile_run listread "$ep" "$en"
  rm -f _build/vibe_selfhost_type_env_* 2>/dev/null || true          # force type recheck w/ source caches
  fs_compile_run typrecheck "$ep" "$en"
  rm -f _build/vibe_selfhost_module_header_* _build/vibe_selfhost_leaf_fp_* 2>/dev/null || true
  fs_compile_run hdrread "$ep" "$en"                                 # force header/leaf re-read
done
cache_clear

# Gather corpus files. errcorpus (malformed / ill-typed programs) is folded into the
# default set: failed compiles now dump their hit bitmap on abort, so the error/
# diagnostic branches (type_to_string, serialize_type, defensive check_expr arms) get
# exercised too.
targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
  # Regenerate the synthetic error/feature corpus (deterministic; committed
  # generator) so the diagnostic + breadth programs are always present.
  [ -x scripts/coverage_gen_errcorpus.sh ] && bash scripts/coverage_gen_errcorpus.sh _build/errcorpus >&2 || true
  targets=(examples fixtures)
  [ -d _build/errcorpus ] && targets+=(_build/errcorpus)
fi
files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$t" -name '*.vibe' | sort)
  elif [ -f "$t" ]; then
    files+=("$t")
  fi
done

i=0; comp_ok=0; norm_ok=0; rc_ok=0
for f in "${files[@]}"; do
  i=$((i+1)); [ "$i" -gt "$MAX" ] && break
  fr="$(rel "$f")"
  # Pick an entry the file actually has, else most files fail entry resolution
  # and contribute NO coverage (a failed compile never dumps the bitmap):
  #   test blocks / no entry -> sentinel (compiler emits a test-running _start)
  #   `main` / `run`         -> that entry
  is_test=0
  if grep -q 'test "' "$f" 2>/dev/null; then
    entry="__no_entry__"; is_test=1
  elif grep -qE '(export )?let main' "$f" 2>/dev/null; then
    entry="main"
  elif grep -qE '(export )?let run' "$f" 2>/dev/null; then
    entry="run"
  else
    entry="__no_entry__"
  fi
  # COMPILE (FS mode; exercises parser/checker/codegen). NB: only COMPILING the
  # corpus exercises the instrumented compiler — running the produced program is
  # pointless here (that program is a different, uninstrumented binary).
  if acc_run env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$fr" "$OUT_DIR/o.wasm" "$entry"; then
    comp_ok=$((comp_ok+1))
  else
    echo "compile $fr" >> "$FAILS"
  fi
  # NORMALIZE (exercises the AST printer).
  if acc_run env VIBE_NORMALIZE=1 \
      bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$fr" "$OUT_DIR/o.vibe"; then
    norm_ok=$((norm_ok+1))
  else
    echo "normalize $fr" >> "$FAILS"
  fi
  # RC: self-contained files (no imports) via the single-source path, which
  # honors VIBE_RC — exercises the Perceus codegen (pc_count/pc_emit/...).
  if ! grep -q '^import ' "$f" 2>/dev/null; then
    acc_run env VIBE_RC=1 VIBE_IMPORT_ABI=raw \
      bash "$RUNNER" --invoke cli_main "$COMPILER_COV" "$fr" "$OUT_DIR/orc.wasm" "$entry" && rc_ok=$((rc_ok+1)) || true
  fi
  if [ $((i % 25)) -eq 0 ] && [ -s "$ACC" ]; then
    python3 -c "
import json;a=json.load(open('$ACC'))
fn=sum(a['fn']);ft=len(a['fn']);br=sum(a['br']);bt=len(a['br'])
print(f'[corpus] {$i} files: fn {fn}/{ft} ({fn/ft*100:.1f}%), branch {br}/{bt} ({br/bt*100:.1f}%)')" >&2
  fi
done

# Final report.
echo "[corpus] workloads: compile_ok=$comp_ok normalize_ok=$norm_ok rc_ok=$rc_ok of $i files" >&2
python3 - "$ACC" "$OUT_DIR/merged.json" "${VIBE_COV_SHOW_BRANCH_GAPS:-0}" "$comp_ok" "$norm_ok" "$i" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
fn, br, names, owners = a["fn"], a["br"], a["fn_names"], a["br_owners"]
ft, bt = len(fn), len(br)
fh, bh = sum(fn), sum(br)
per_fn = {}
for bid, ow in enumerate(owners):
    nm = names[ow] if 0 <= ow < len(names) else f"#{ow}"
    e = per_fn.setdefault(nm, {"total": 0, "hit": 0}); e["total"] += 1; e["hit"] += br[bid]
gaps = sorted(({"fn": n, "taken": e["hit"], "total": e["total"]} for n, e in per_fn.items() if e["hit"] < e["total"]),
              key=lambda g: g["total"]-g["taken"], reverse=True)
out = {"compile_ok": int(sys.argv[4]), "normalize_ok": int(sys.argv[5]), "files": int(sys.argv[6]),
       "total": ft, "hit": fh, "rate": fh/ft if ft else 0,
       "missed_fns": [names[i] for i,v in enumerate(fn) if not v],
       "branch": {"total": bt, "hit": bh, "rate": bh/bt if bt else 0, "per_fn": per_fn, "top_gaps": gaps[:60]}}
json.dump(out, open(sys.argv[2], "w"), indent=2)
print(f"[corpus] FILES={sys.argv[6]} compile_ok={sys.argv[4]} normalize_ok={sys.argv[5]}")
print(f"[corpus] MERGED: functions {fh}/{ft} ({fh/ft*100:.2f}%), branches {bh}/{bt} ({bh/bt*100:.2f}%)")
if sys.argv[3] == "1":
    print("top branch gaps:")
    for g in gaps[:30]:
        print(f"  {g['fn']}: {g['taken']}/{g['total']}")
PY
echo "[corpus] report: $OUT_DIR/merged.json ; fails: $FAILS" >&2
