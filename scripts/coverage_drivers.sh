#!/usr/bin/env bash
# Selfhost coverage DRIVER suite (#cov): push branch coverage past what the
# black-box corpus (coverage_corpus.sh) reaches. The corpus compiles
# example/fixture programs through one instrumented compiler; it saturates the
# common paths but structurally cannot reach:
#   - cli_main-unreachable helpers (DCE'd from the shipped compiler binary)
#   - inlined async/stream builtins, less-common Array/IO builtins
#   - on-disk cache-format parsers and their version/arity/error arms
#   - TypeEnv-walking trait helpers fed only checker-built shapes
#   - the linked_imports>0 / library_mode arms of compile_wasi_module_linked_impl
#
# Drivers compile and run against a cycle-free no-DCE compiler source under
# coverage, unioning executed branches into the corpus acc.json by
# (fn_name, local_branch_index) — valid because every binary shares the same
# per-function branch ordering. The migrated `units` and `traitenv` drivers are
# merged by compiler-owned exact-path exposure mode; remaining drivers retain
# the legacy raw base until later #1633 slices. Run coverage_corpus.sh FIRST (it
# builds acc.json + the instrumented compiler_cov.wasm this suite reuses).
#
#   scripts/coverage_drivers.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="${VIBE_COV_SEED:-bootstrap/seed/compiler.wasm}"
OUTDIR="_build/coverage/selfhost-corpus"
ACC="$OUTDIR/acc.json"
COMPILER_COV="$OUTDIR/compiler_cov.wasm"
COMPILER_ENTRY="lib/@vibe/compiler/cli_adapter.vibe"
DRIVER_FILTER="${VIBE_COV_DRIVER_FILTER:-}"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
# Same node-stack requirement as coverage_corpus.sh: every driver compiles the
# ~5MB merged source (plus the driver) under coverage instrumentation, which
# recurses past node's default stack. Without this the host overflow surfaces as
# `expression too deeply nested`, run_driver counts it as a compile failure, and
# -- because that path used to `return 0` -- the whole suite reported success
# with EVERY driver silently skipped. Keep in sync with coverage_corpus.sh.
export VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --experimental-wasm-inlining --stack-size=131072}"
MERGED="_build/coverage/merged_nodce.vibe"
WORK="_build/coverage/drivers"

# Split out one attempt so the deterministic-vs-transient retry contract has a
# focused shell test without invoking the full coverage corpus.
coverage_driver_compile_once() { # dir entry
  local driver_dir="$1" entry="$2"
  VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$SEED" "$driver_dir/src.vibe" "$driver_dir/m.wasm" "$entry" >"$driver_dir/compile.log" 2>&1
}

COVERAGE_DRIVER_COMPILE_ATTEMPTS=0
coverage_driver_compile_with_retries() { # dir entry
  local driver_dir="$1" entry="$2" attempt
  COVERAGE_DRIVER_COMPILE_ATTEMPTS=0
  for attempt in 1 2 3 4 5 6; do
    COVERAGE_DRIVER_COMPILE_ATTEMPTS="$attempt"
    rm -f "$driver_dir/m.wasm" "$driver_dir/m.wasm.diag"
    coverage_driver_compile_once "$driver_dir" "$entry" || true
    [ -s "$driver_dir/m.wasm" ] && return 0
    # A compiler diagnostic is deterministic. Only host/OOM failures without a
    # diagnostic are eligible for another attempt.
    [ -s "$driver_dir/m.wasm.diag" ] && return 2
  done
  return 1
}

cd "$ROOT" || exit 1
COVERAGE_DRIVERS_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  COVERAGE_DRIVERS_SOURCED=1
else
  [ -s "$ACC" ] || { echo "drivers: run coverage_corpus.sh first (no acc.json)" >&2; exit 1; }
  [ -s "$COMPILER_COV" ] || { echo "drivers: run coverage_corpus.sh first (no current compiler_cov.wasm)" >&2; exit 1; }
  mkdir -p "$WORK"
fi

coverage_driver_uses_exact_exposure() { # label
  case "$1" in
    units|traitenv) return 0 ;;
    *) return 1 ;;
  esac
}

# 1. Regenerate the legacy no-DCE source only for drivers not yet migrated to
#    exact-path exposure. Filtered exact-exposure runs never construct or trust
#    raw concatenation; an unfiltered run still needs it for legacy drivers.
if [ "$COVERAGE_DRIVERS_SOURCED" = "0" ] && { [ -z "$DRIVER_FILTER" ] || ! coverage_driver_uses_exact_exposure "$DRIVER_FILTER"; }; then
  echo "[drivers] regenerating legacy no-DCE source ..." >&2
  python3 - "lib/@vibe/compiler" "lib/@vibe/compiler/compiler_sources_manifest.tsv" "cli_adapter.vibe" "$MERGED" <<'PY'
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
fi

# (fn_name, local_branch_index) union of a driver's raw coverage dump into
# acc.json -- scripts/coverage_local_merge.vibex's `merge` subcommand (native
# vibe port; see that file's header comment for the algorithm).

coverage_driver_stat() { # acc_path
  local stat_out hit total extra
  stat_out="$(bash scripts/coverage_acc_tool_run.sh stat "$1")" || return 1
  # Command substitution strips trailing newlines, so require exactly one
  # non-empty record and reject embedded/trailing records fail-closed.
  [[ "$stat_out" != *$'\n'* ]] || return 1
  read -r hit total extra <<<"$stat_out"
  [ -z "${extra:-}" ] || return 1
  [[ "$hit" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
  [ "$total" -gt 0 ] || return 1
  [ "$hit" -le "$total" ] || return 1
  printf '%s %s\n' "$hit" "$total"
}

coverage_driver_merge_checked() { # acc_path run_path
  local acc="$1" run="$2" before_stat before_hit before_total merge_out base now total extra after_stat after_hit after_total
  before_stat="$(coverage_driver_stat "$acc")" || return 1
  read -r before_hit before_total <<<"$before_stat"
  merge_out="$(VIBE_COVERAGE_LOCAL_MERGE_COMPILER="$COMPILER_COV" \
    bash scripts/coverage_local_merge_run.sh merge "$acc" "$run")" || return 1
  [[ "$merge_out" != *$'\n'* ]] || return 1
  read -r base now total extra <<<"$merge_out"
  [ -z "${extra:-}" ] || return 1
  [[ "$base" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
  [ "$base" -eq "$before_hit" ] || return 1
  [ "$total" -eq "$before_total" ] || return 1
  [ "$total" -gt 0 ] || return 1
  [ "$now" -ge "$base" ] && [ "$now" -le "$total" ] || return 1
  after_stat="$(coverage_driver_stat "$acc")" || return 1
  read -r after_hit after_total <<<"$after_stat"
  [ "$after_hit" -eq "$now" ] && [ "$after_total" -eq "$total" ] || return 1
  printf '%s %s %s\n' "$base" "$now" "$total"
}

if [ "$COVERAGE_DRIVERS_SOURCED" = "1" ]; then
  return 0
fi

# Run one driver: append <driver>.vibe to the merged source, compile under
# coverage with the driver entry, run, union into acc.json. Retries: the 36k-line
# source occasionally OOMs the seed under instrumentation.
# A driver that cannot compile, or that dumps no coverage, means its branches
# were NOT measured. Both used to be a note on stderr and `return 0`, so the
# suite finished green and printed its usual summary line -- indistinguishable
# from a run where everything worked. That is how the whole suite came to be
# 0-for-34 without anyone noticing (#1631): the numbers just stopped improving.
# Count them and fail the suite at the end (after running every driver, so one
# breakage does not hide the rest).
DRIVER_FAILS=0
DRIVERS_RAN=0

run_driver() { # entry driver_file label
  local entry="$1" file="$2" label="$3"
  if [ -n "$DRIVER_FILTER" ] && [ "$DRIVER_FILTER" != "$label" ]; then
    return 0
  fi
  DRIVERS_RAN=$((DRIVERS_RAN + 1))
  local d="$WORK/$label"; rm -rf "$d"; mkdir -p "$d"
  if coverage_driver_uses_exact_exposure "$label"; then
    # The current instrumented compiler owns this internal emit mode. It
    # collects the production compiler closure, resolves the driver's exact-file
    # value requests, and rewrites them to the ordinary merge's final names.
    # The pinned seed only compiles the emitted ordinary source; no seed bump.
    rm -f "$d/src.vibe" "$d/src.vibe.diag"
    VIBE_EMIT_COVERAGE_DRIVER_SOURCE=1 \
      VIBE_COVERAGE_DRIVER_PATH="$file" \
      VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
      bash "$RUNNER" --invoke cli_main "$COMPILER_COV" \
      "$COMPILER_ENTRY" "$d/src.vibe" "$entry" >"$d/expose.log" 2>&1 || true
    if [ ! -s "$d/src.vibe" ]; then
      echo "[$label] exact-path exposure failed" >&2
      if [ -s "$d/src.vibe.diag" ]; then
        awk '{ print "               " $0 }' "$d/src.vibe.diag" >&2
      elif [ -s "$d/expose.log" ]; then
        tail -3 "$d/expose.log" | awk '{ print "               " $0 }' >&2
      fi
      DRIVER_FAILS=$((DRIVER_FAILS + 1))
      return 0
    fi
  else
    cat "$MERGED" "$file" > "$d/src.vibe"
  fi
  local compile_status=0
  coverage_driver_compile_with_retries "$d" "$entry" || compile_status=$?
  if [ "$compile_status" != 0 ]; then
    # Surface deterministic diagnostics immediately; only diagnostic-free host
    # failures consume the six-attempt retry budget.
    if [ "$compile_status" = 2 ]; then
      echo "[$label] deterministic compile failure (not retried)" >&2
    else
      echo "[$label] compile failed after $COVERAGE_DRIVER_COMPILE_ATTEMPTS transient attempts" >&2
    fi
    # awk, not sed: the compiler writes the sidecar WITHOUT a trailing newline,
    # and sed passes that through -- so the reason ran straight into the next
    # driver's line (`unknown name: db_new[round] compile failed ...`). awk's
    # `print` always terminates the line it emits.
    if [ -s "$d/m.wasm.diag" ]; then
      awk '{ print "               " $0 }' "$d/m.wasm.diag" >&2
    elif [ -s "$d/compile.log" ]; then
      tail -3 "$d/compile.log" | awk '{ print "               " $0 }' >&2
    fi
    DRIVER_FAILS=$((DRIVER_FAILS + 1))
    return 0
  fi
  VIBE_COV_OUT="$d/cov.json" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT" \
    bash "$RUNNER" "$d/m.wasm" >/dev/null 2>&1 || true
  if [ -s "$d/cov.json" ]; then
    local merge_stat
    if merge_stat="$(coverage_driver_merge_checked "$ACC" "$d/cov.json")"; then
      read -r base now tot <<<"$merge_stat"
      scaled=$(( (now * 10000 + tot / 2) / tot ))
      pct="$((scaled / 100)).$(printf '%02d' $((scaled % 100)))"
      echo "[$label] $base -> $now/$tot ($pct%) (+$((now-base)))"
    else
      echo "[$label] local coverage merge failed validation" >&2
      DRIVER_FAILS=$((DRIVER_FAILS + 1))
    fi
  else
    echo "[$label] no coverage dumped" >&2
    DRIVER_FAILS=$((DRIVER_FAILS + 1))
  fi
}

# covproj/a.vibe etc. must exist for the Fs-validator driver (cov_units2).
mkdir -p _build/covproj
printf 'export let a_val: () -> Int = () -> { 41 }\n' > _build/covproj/a.vibe
printf 'import ./a.vibe { a_val }\nexport let b_val: () -> Int = () -> { a_val() }\n' > _build/covproj/b.vibe
printf 'export let c_val: () -> Int = () -> { 5 }\n' > _build/covproj/c.vibe
# covfs/f.vibe is the real fixture cov_fscache reads its stat-token/fingerprint from.
mkdir -p _build/covfs
printf 'export let f: () -> Int = () -> { 123 }\n' > _build/covfs/f.vibe
mkdir -p _build/covfs2
printf 'export let m: () -> Int = () -> { 7 }\n' > _build/covfs2/main.vibe
printf '# group\tpath\ngrp\tmain.vibe\n' > _build/covfs2/compiler_sources_manifest.tsv

initial_stat="$(coverage_driver_stat "$ACC")" || {
  echo "drivers: invalid or empty acc.json statistics" >&2
  exit 1
}
read -r base _ <<<"$initial_stat"
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
run_driver cov_fs2_main        scripts/coverage/cov_fs2.vibe        fs2         # build_module_source_from_source + cold collect_all_sources_fs/collect_source_groups_fs/load_persistent_*
run_driver cov_serialize_main  scripts/coverage/cov_serialize.vibe  serialize   # serialize_type<->parse_cached_type round-trip + grouped-source accumulators + collect_private_type_renames
run_driver cov_remainder_main  scripts/coverage/cov_remainder.vibe  remainder   # literal_type/annotate_literal_let/build_pull_for_in/skip_brace_list/collect_import_path/has_non_pipe_infix_top/exported_value_names
run_driver cov_grab_main       scripts/coverage/cov_grab.vibe       grab        # long-tail type/trait/env/heap/token/AST helpers (type_to_string/trait_*/env_*/is_heap_literal/...)
run_driver cov_lookup2_main    scripts/coverage/cov_lookup2.vibe    lookup2     # every dark lookup_* builtin dispatcher x full builtin-name union (generated)
run_driver cov_parser3_main    scripts/coverage/cov_parser3.vibe    parser3     # parse_postfix expr-type stop-cases + parse_impl mode dispatch + parse_impl_block bodies (direct via parse_impl callback)
run_driver cov_parser4_main    scripts/coverage/cov_parser4.vibe    parser4     # parse_pattern/parse_type_impl/parse_stmt/parse_*_primary/parse_*_stmt internals (direct, lexed tokens)
run_driver cov_namespace_main  scripts/coverage/cov_namespace.vibe  namespace   # namespace_private_value_stmts: private+exported enum/struct/suberror/alias body with ctor/type rewrites
run_driver cov_push85_main     scripts/coverage/cov_push85.vibe     push85      # has_non_pipe_infix_top depth cases + collect_import_path/scan_header_import_dep + namespace SImpl body
run_driver cov_block_main      scripts/coverage/cov_block.vibe      block       # parse_impl_block block-local let-rec/mut/enum/struct + eof/identifier error throws
run_driver cov_walk3_main      scripts/coverage/cov_walk3.vibe      walk3       # expr_projects_or_matches/is_mut_captured_in residual name-in-sub-position recursion arms
run_driver cov_cache2_main     scripts/coverage/cov_cache2.vibe     cache2      # normalize_path / parse_source_manifest_rows / parse_persistent_manifest_header_cache string arms
run_driver cov_final_main      scripts/coverage/cov_final.vibe      final       # entry_declares_async_int async-entry sigs + collect_import_path + grouped-source/module-alias accumulators
run_driver cov_final2_main     scripts/coverage/cov_final2.vibe     final2      # print_stmt type-decl variants + env_lookup/resolve_type_expr/rewrite_import_alias_expr/scan_header_import_dep residuals
run_driver cov_typeeq_main     scripts/coverage/cov_typeeq.vibe     typeeq      # types_equal/unify CtNamed/CtTuple/CtFn/CtForAll loop-mismatch-mid-iteration arms
run_driver cov_grind_main      scripts/coverage/cov_grind.vibe      grind       # collect_private_type_renames exported-skip arms + collect_needed_paths_from_manifest_headers rows-lookup
run_driver cov_grind2_main     scripts/coverage/cov_grind2.vibe     grind2      # namespace_private_value_stmts STest/SBench/SLetPat/SExternLet ref-rewrite + parse_perform/generic/call_arg primaries
run_driver cov_margin_main     scripts/coverage/cov_margin.vibe     margin      # parse_perform_primary stop-tokens + parse_call_arg ->/~=/?= forms + parse_generic_fn_primary bracket-depth
run_driver cov_parser5_main    scripts/coverage/cov_parser5.vibe    parser5     # parse_type_impl modes x type forms + parse_pattern/parse_export_stmt/parse_one_param internals
run_driver cov_namespace3_main scripts/coverage/cov_namespace3.vibe namespace3  # namespace_private_value_stmts SModule/SImpl/SEffectDef/SReExport/SAliasDecl arms
run_driver cov_round_main      scripts/coverage/cov_round.vibe      round       # parse_enum_stmt/parse_export_name forms + print_stmt SImpl/SModule/SReExport/SEffectDef variants + has_non_pipe_infix_top ranges
rm -f _build/vibe_selfhost_* 2>/dev/null || true

final_stat="$(coverage_driver_stat "$ACC")" || {
  echo "[drivers] FAIL: invalid final accumulator statistics" >&2
  exit 1
}
read -r now tot <<<"$final_stat"
scaled=$(( (now * 10000 + tot / 2) / tot ))
pct="$((scaled / 100)).$(printf '%02d' $((scaled % 100)))"
echo "[drivers] corpus branches: $base -> $now/$tot ($pct%)  (+$((now-base)))" >&2

# Without this the line above is the whole story, and `+0` reads as "the
# drivers added nothing new" rather than "no driver ran". Never report a
# coverage number as if it came from a complete run when it did not.
if [ "$DRIVERS_RAN" -eq 0 ]; then
  echo "[drivers] FAIL: VIBE_COV_DRIVER_FILTER='$DRIVER_FILTER' selected no driver" >&2
  exit 1
fi
if [ "$DRIVER_FAILS" -gt 0 ]; then
  echo "[drivers] FAIL: $DRIVER_FAILS driver(s) did not contribute coverage (see the per-driver reasons above)" >&2
  echo "[drivers] the branch numbers above are therefore INCOMPLETE" >&2
  exit 1
fi
