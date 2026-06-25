#!/usr/bin/env bash
# Selfhost coverage DRIVER suite (#cov): push branch coverage past what the
# black-box corpus (coverage_selfhost_corpus.sh) reaches. The corpus compiles
# example/fixture programs through one instrumented compiler; it saturates the
# common paths but structurally cannot reach:
#   - cli_main-unreachable helpers (DCE'd from the shipped compiler binary)
#   - inlined async/stream builtins, less-common Array/IO builtins
#   - on-disk cache-format parsers and their version/arity/error arms
#   - TypeEnv-walking trait helpers fed only checker-built shapes
#   - the linked_imports>0 / library_mode arms of compile_wasi_module_linked_impl
#
# Each driver below APPENDS a small entry to the cycle-free *no-DCE merged source*
# (every top-level fn in scope, no import cycle) and compiles+runs it under
# coverage, unioning the executed branches into the corpus acc.json by
# (fn_name, local_branch_index) — valid because every binary shares the same
# per-function branch ordering. Run coverage_selfhost_corpus.sh FIRST (it builds
# acc.json + the instrumented compiler_cov.wasm this suite reuses).
#
#   scripts/coverage_selfhost_drivers.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SEED="${VIBE_COV_SEED:-bootstrap/selfhost/seed/selfhost_compiler.wasm}"
OUTDIR="_build/coverage/selfhost-corpus"
ACC="$OUTDIR/acc.json"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
MERGED="_build/coverage/merged_nodce.vibe"
WORK="_build/coverage/drivers"; mkdir -p "$WORK"
[ -s "$ACC" ] || { echo "drivers: run coverage_selfhost_corpus.sh first (no acc.json)" >&2; exit 1; }

# 1. Regenerate the no-DCE merged source: every manifest file, imports stripped,
#    concatenated (the pre-DCE input to build_module_source_from_source). This is
#    the base every driver appends to.
echo "[drivers] regenerating no-DCE merged source ..." >&2
python3 - "vibe/compiler" "vibe/compiler/selfhost_sources_manifest.tsv" "selfhost_cli_adapter.vibe" "$MERGED" <<'PY'
import os, re, sys
compiler_dir, manifest_path, root_rel, out_path = sys.argv[1:]
rows=[]
for raw in open(manifest_path):
    line=raw.rstrip("\n")
    if not line or line.startswith("#"): continue
    p=line.split("\t")
    if len(p)==2: rows.append((p[0],p[1]))
src_by={}
for _,rel in rows:
    full=os.path.join(compiler_dir,rel)
    if os.path.isfile(full): src_by[rel]=open(full,encoding="utf-8").read()
dep=re.compile(r'^\s*(?:import|export)\s+(\.[\w./\s-]+?)(?:\.vibe)?\s*\{',re.M)
drop=re.compile(r'^\s*(?:import|export)\s+[.][^\s{]+')
def norm(p):
    out=[]
    for s in p.split("/"):
        if s in("","."):continue
        if s=="..":
            if out:out.pop()
            continue
        out.append(s)
    return "/".join(out)
def resolve(base,raw):
    bd=os.path.dirname(base); raw=re.sub(r'\s*/\s*','/',raw.strip())
    j=norm((bd+"/"+raw) if (raw.startswith("./") or raw.startswith("../")) and bd else raw)
    cands=[j] if j.endswith(".vibe") else [j+".vibe", j+"/index.vibe"]
    for c in cands:
        if c in src_by: return c
    return cands[0]
vis=set(); order=[]
def visit(rel):
    if rel in vis: return
    s=src_by.get(rel)
    if s is None: return
    vis.add(rel)
    for d in dep.findall(s): visit(resolve(rel,d))
    order.append(rel)
def strip(s):
    out=[]; skip=False; depth=0
    for line in s.splitlines(True):
        st=line.lstrip()
        if st.startswith("//"): continue
        if not skip and drop.match(line):
            depth=line.count("{")-line.count("}")
            if depth>0: skip=True
            continue
        if skip:
            depth+=line.count("{")-line.count("}")
            if depth<=0: skip=False
            continue
        out.append(line)
    m="".join(out)
    return m if (not m or m.endswith("\n")) else m+"\n"
visit(root_rel)
first=True
with open(out_path,"w",encoding="utf-8") as f:
    for rel in order:
        s=src_by.get(rel)
        if s is None: continue
        m=strip(s)
        if first: m=m.lstrip("\r\n"); first=False
        f.write(m)
PY
[ -s "$MERGED" ] || { echo "drivers: merged source generation failed" >&2; exit 1; }

# (fn_name, local_branch_index) union of a driver's raw coverage dump into acc.json
cat > "$WORK/merge.py" <<'PY'
import json, sys, os
from collections import defaultdict
acc=json.load(open(sys.argv[1])); fnC,owC,brC=acc['fn_names'],acc['br_owners'],acc['br']
localC=defaultdict(list)
for gid,o in enumerate(owC):
    nm=fnC[o] if 0<=o<len(fnC) else None
    if nm is not None: localC[nm].append(gid)
base=sum(brC)
raw=json.load(open(sys.argv[2]))['raw']
nT,owT,bmT=raw['fn_names'],raw['branch_owners'],raw['branch_bitmap']
seen=defaultdict(int)
for i,o in enumerate(owT):
    nm=nT[o] if 0<=o<len(nT) else None
    li=seen[nm]; seen[nm]+=1
    if nm is None or not bmT[i]: continue
    ids=localC.get(nm)
    if ids and li<len(ids): brC[ids[li]]=1
tmp=sys.argv[1]+'.tmp'; json.dump(acc,open(tmp,'w')); os.replace(tmp,sys.argv[1])
print(f"[{sys.argv[3]}] {base} -> {sum(brC)}/{len(brC)} ({sum(brC)/len(brC)*100:.2f}%) (+{sum(brC)-base})")
PY

# Run one driver: append <driver>.vibe to the merged source, compile under
# coverage with the driver entry, run, union into acc.json. Retries: the 36k-line
# source occasionally OOMs the seed under instrumentation.
run_driver() { # entry driver_file label
  local entry="$1" file="$2" label="$3"
  local d="$WORK/$label"; rm -rf "$d"; mkdir -p "$d"
  cat "$MERGED" "$file" > "$d/src.vibe"
  local ok=0 t
  for t in 1 2 3 4 5 6; do
    rm -f "$d/m.wasm"
    VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT" VIBE_SELFHOST_IMPORT_ABI=raw \
      bash "$RUNNER" --invoke cli_main "$SEED" "$d/src.vibe" "$d/m.wasm" "$entry" >/dev/null 2>&1 || true
    [ -s "$d/m.wasm" ] && { ok=1; break; }
  done
  [ "$ok" = 1 ] || { echo "[$label] compile failed after retries" >&2; return 0; }
  VIBE_COV_OUT="$d/cov.json" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT" \
    bash "$RUNNER" "$d/m.wasm" >/dev/null 2>&1 || true
  [ -s "$d/cov.json" ] && python3 "$WORK/merge.py" "$ACC" "$d/cov.json" "$label" || echo "[$label] no coverage dumped" >&2
}

# covproj/a.vibe etc. must exist for the Fs-validator driver (cov_units2).
mkdir -p _build/covproj
printf 'export let a_val: () -> Int = () -> { 41 }\n' > _build/covproj/a.vibe
printf 'import ./a.vibe { a_val }\nexport let b_val: () -> Int = () -> { a_val() }\n' > _build/covproj/b.vibe
printf 'export let c_val: () -> Int = () -> { 5 }\n' > _build/covproj/c.vibe
# covfs/f.vibe is the real fixture cov_fscache reads its stat-token/fingerprint from.
mkdir -p _build/covfs
printf 'export let f: () -> Int = () -> { 123 }\n' > _build/covfs/f.vibe

base=$(python3 -c "import json;print(sum(json.load(open('$ACC'))['br']))")
run_driver cov_async_main      scripts/coverage/cov_async.vibe      async       # inlined async/stream builtins
run_driver cov_builtins_main   scripts/coverage/cov_builtins.vibe   builtins    # Array/String/Map/Bytes builtins
run_driver cov_lookup_main     scripts/coverage/cov_lookup.vibe     lookup      # builtin name->Type dispatch chains
run_driver cov_cachetext_main  scripts/coverage/cov_cachetext.vibe  cachetext   # persistent-cache format parsers
run_driver cov_units_main      scripts/coverage/cov_units.vibe      units       # pure helpers (strip_cr, dce, assignop, iter)
run_driver cov_units2_main     scripts/coverage/cov_units2.vibe     units2      # Fs validators + parse helpers
run_driver cov_traitenv_main   scripts/coverage/cov_traitenv.vibe   traitenv    # type_implements_check_super env walk
run_driver cov_link_main       scripts/coverage/cov_link.vibe       link        # compile_wasi_module_linked_impl arms
run_driver cov_parse_main      scripts/coverage/cov_parse.vibe      parse       # parser arms (impl/postfix/pattern)
run_driver cov_helpers_main    scripts/coverage/cov_helpers.vibe    helpers     # unique pure helpers: valtype/int/io-dispatch/double/async-int
run_driver cov_syntax_main     scripts/coverage/cov_syntax.vibe     syntax      # parser arms: slices/block-local let-rec-mut/enum-struct/impl/match-modes
run_driver cov_exprwalk_main   scripts/coverage/cov_exprwalk.vibe   exprwalk    # Expr/Pat walkers: is_mut_captured_in/rewrite_import_alias_expr/wrap_placeholder_arg/pat_binds_name
run_driver cov_fscache_main    scripts/coverage/cov_fscache.vibe    fscache     # Fs validator load_source_if_cached_file_spec_matches: every stat-token/fingerprint arm
run_driver cov_parser2_main    scripts/coverage/cov_parser2.vibe    parser2     # parser error/exotic arms via malformed+rare syntax through load_and_parse
run_driver cov_walker2_main    scripts/coverage/cov_walker2.vibe    walker2     # print_expr/print_stmt + Stmt/Expr/Pat predicate walkers (full-variant)
run_driver cov_checker_main    scripts/coverage/cov_checker.vibe    checker     # unify/occurs_in/subst_apply/subst_lookup + types_equal deep residual
run_driver cov_transform_main  scripts/coverage/cov_transform.vibe  transform   # resolve_type_expr/type_contains_fn/env_lookup/trait_supers/rewrite_*/namespace + Pat/TypeExpr walkers
run_driver cov_misc_main       scripts/coverage/cov_misc.vibe       misc        # stmt_section/is_expr_end_token/has_non_pipe_infix_top/check_pattern/module_value_aliases/flatten_module_body
rm -f _build/vibe_selfhost_* 2>/dev/null || true

now=$(python3 -c "import json;print(sum(json.load(open('$ACC'))['br']))")
tot=$(python3 -c "import json;print(len(json.load(open('$ACC'))['br']))")
echo "[drivers] corpus branches: $base -> $now/$tot ($(python3 -c "print(f'{$now/$tot*100:.2f}')")%)  (+$((now-base)))" >&2
