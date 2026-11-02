#!/usr/bin/env bash
# Selfhost `vibe test` (#594): compile a .vibe test file (resolving imports from
# the filesystem) with the committed seed compiler, then execute it via the Rust
# runner — no MoonBit host.
#
#   bash scripts/vibe_test.sh [--coverage] [--update] <path.vibe | dir> [more paths...]
#
# A test file declares `test "name" { ... }` blocks and (typically) no entry
# function. The selfhost compiler lowers each block into a `__test_<name>`
# function and, when the file has no entry, emits a `_start` that runs every
# test in sequence. `assert` / `assert_eq` trap (wasm `unreachable`) on failure,
# so a clean `_start` run means all of the file's tests passed; a trap means at
# least one failed. Reporting is per file (all-or-nothing); per-test reporting
# is a follow-up. Paths must live under the repo root (the wasm preopen dir).
#
# --coverage (#cov): compile each test file with function/branch hit
# instrumentation, then read the bitmap after a passing run to report which of
# the file's (and its imports') functions and if/match branches the tests
# exercised. Per-file lines + an aggregate are printed; per-file JSON reports
# land in _build/vibe_test/coverage/.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash "$ROOT_DIR/scripts/ensure_seed.sh"
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
outdir="$ROOT_DIR/_build/vibe_test"
mkdir -p "$outdir"
vt_results="$(mktemp -d -t vibe-test-results-XXXXXX)"
trap 'rm -rf "$vt_results"' EXIT

# Every decision this script prints is scripts/test_report.vibex's (#3674):
# the argument grammar, each file's line and result record, the summary and
# the report under `FAIL <file>` (@vibe/testrun, @vibe/testreport). What stays
# here is what only a host does: choosing and launching the compiler and the
# runner, timeouts, the worker fan-out and the exit status.
#
# The tool is compiled with the committed SEED, never with VIBE_TEST_CLI_WASM:
# the compiler under test must not be able to change how its own results are
# reported. Once per run, before anything else, into the run's results dir.
vt_tool_wasm="$vt_results/test_report.wasm"
if ! ( cd "$ROOT_DIR" && VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    "$BASH" "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "$seed" \
    scripts/test_report.vibex "$vt_tool_wasm" main ) >"$vt_results/test_report.compile.log" 2>&1 \
    || [ ! -s "$vt_tool_wasm" ]; then
  echo "vibe_test.sh: scripts/test_report.vibex did not compile with the seed ($seed):" >&2
  sed 's/^/  /' "$vt_results/test_report.compile.log" >&2
  [ -s "$vt_tool_wasm.diag" ] && sed 's/^/  /' "$vt_tool_wasm.diag" >&2
  exit 2
fi
# Both run through "$BASH", the interpreter running this script, rather than
# whatever `bash` PATH names: scripts/vibe_test_smoke.sh fakes the compiler and
# runner with a PATH `bash`, and the tool must keep answering under it.
vt_tool() {
  ( cd "$ROOT_DIR" && VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_RUNNER_QUIET_RESULT=1 \
      "$BASH" "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke main "$vt_tool_wasm" "$@" )
}
export ROOT_DIR vt_tool_wasm
export -f vt_tool

# The options and paths, or the grammar's own message and exit 2: an
# unrecognised option is named as one (#2886), no path is the usage line, and
# VIBE_TEST_BACKEND=gc refuses --coverage (linear-only instrumentation).
vt_plan_status=0
vt_plan="$(vt_tool plan "$@")" || vt_plan_status=$?
[ "$vt_plan_status" = 0 ] || exit "$vt_plan_status"
coverage=0
update=0
_args=()
while IFS= read -r vt_line; do
  case "$vt_line" in
    "coverage "*) coverage="${vt_line#coverage }" ;;
    "update "*) update="${vt_line#update }" ;;
    "path "*) _args+=("${vt_line#path }") ;;
  esac
done <<<"$vt_plan"
set -- ${_args[@]+"${_args[@]}"}

# #683/#2376: VIBE_TEST_BACKEND=gc resolves the same filesystem module graph as
# the linear lane and selects wasm-gc only at the final codegen boundary. It
# runs the result under wasmtime with the gc feature flags instead of the node
# host runner.
backend="${VIBE_TEST_BACKEND:-linear}"
# VIBE_TEST_CLI_WASM overrides the compiling CLI (default: the committed
# seed). The gc lane's test-block lowering (#683) postdates older seeds, so
# gc runs typically pass a freshly built stage2 here.
cli_wasm="${VIBE_TEST_CLI_WASM:-$seed}"
# A missing compiling CLI used to surface as `FAIL (compile)` on EVERY file --
# the same line a genuinely broken test file produces. That reads as "the tests
# are broken" when the truth is "there is no compiler here", and the usual
# cause is a stale VIBE_TEST_CLI_WASM naming a generation directory that no
# longer matches HEAD. Say which it is.
if [ ! -f "$cli_wasm" ]; then
  echo "vibe_test.sh: compiling CLI not found: $cli_wasm" >&2
  if [ -n "${VIBE_TEST_CLI_WASM:-}" ]; then
    echo "  (from VIBE_TEST_CLI_WASM; a generation dir is named for the commit it was built at)" >&2
  fi
  exit 2
fi

# Say, up front, which compiler answered -- and whether that compiler is older
# than the compiler sources in this checkout.
#
# The seed default is right for testing library code and wrong for testing a
# change to the compiler, and the two are indistinguishable from the result.
# There is already a note for this below, but it fires only when a file FAILS
# to compile. The dangerous case is the opposite one: the file compiles, the
# tests run, and the seed returns a confident answer about a compiler that does
# not contain your change. Measured instance, one file, `x - y` through a
# labeled-argument lambda: the seed says 0 (a bug fixed in #1925) and a stage2
# built from the same checkout says -7 (#1899). Neither run reports an error.
# Nothing in the output distinguished them, so the wrong one was believed --
# and the same mistake had already been made twice in that session.
#
# `[ensure-seed] ... bootstrap/seed/compiler.wasm` is printed above and is not
# enough: it names the file without saying that the file is behind.
if [ -z "${VIBE_TEST_CLI_WASM:-}" ] && [ "${VIBE_TEST_QUIET_COMPILER_NOTE:-0}" != "1" ]; then
  seed_src_commit="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1]))["seed"].get("source_commit", ""))
except Exception:
    print("")' "$ROOT_DIR/bootstrap/seed.json" 2>/dev/null || true)"
  # Over-approximate the compiler's inputs, for the reason
  # scripts/ensure_generated.sh:117 already gives about its own fingerprint:
  # the flatten walks cli_adapter.vibe's entire import closure, which reaches
  # well past lib/@vibe/compiler. compiler_sources_manifest.tsv lists
  # @vibe/ast, parser, core, cache, graph, json and lsp as compiler sources,
  # so a change confined to lib/@vibe/parser/lexer.vibe is a compiler change
  # that lib/@vibe/compiler|cli cannot see. Over-approximating costs an
  # occasional notice on a library-only edit; under-approximating stays silent
  # for exactly the case this notice exists to catch.
  #
  # No exclusion list. ensure_generated.sh needs one because it hashes the
  # working tree directly; git does not, and the two things that would have
  # been on it are already handled:
  #
  #   - the five build outputs are gitignored (.gitignore:57-61), so they
  #     cannot show up as uncommitted;
  #   - tests and benches would only ever inflate the commit count, and the
  #     notice reports "you are ahead", not a precise figure.
  #
  # Measured over the current seed window, excluding them changes 44 to 44 --
  # while narrowing to lib/@vibe/compiler|cli changes it to 42, which is the
  # under-approximation this notice exists to avoid.
  compiler_paths=(lib/@vibe lib/@vibex)
  behind=""
  if [ -n "$seed_src_commit" ] && \
    git -C "$ROOT_DIR" cat-file -e "$seed_src_commit^{commit}" 2>/dev/null; then
    behind="$(git -C "$ROOT_DIR" rev-list --count "$seed_src_commit"..HEAD \
      -- "${compiler_paths[@]}" 2>/dev/null || true)"
  fi
  # Uncommitted edits count too, and are the case where the gap is likeliest to
  # be the thing under test.
  dirty="$(git -C "$ROOT_DIR" status --porcelain -- "${compiler_paths[@]}" 2>/dev/null \
    | wc -l | tr -d ' ')"
  if [ "${behind:-0}" != "0" ] || [ "${dirty:-0}" != "0" ]; then
    gap=""
    [ "${behind:-0}" != "0" ] && gap="$behind commit(s)"
    if [ "${dirty:-0}" != "0" ]; then
      [ -n "$gap" ] && gap="$gap and "
      gap="$gap$dirty uncommitted file(s)"
    fi
    echo "[vibe-test] compiler: the committed seed -- $gap ahead of it under lib/@vibe|@vibex." >&2
    echo "[vibe-test]   This run CANNOT observe those changes; a green result here says nothing about them." >&2
    echo "[vibe-test]   To test this checkout's compiler:" >&2
    echo "[vibe-test]     VIBE_TEST_CLI_WASM=_build/selfhost/generations/<gen>_\$(git rev-parse --short HEAD)/stage2.wasm" >&2
  fi
fi

covdir="$outdir/coverage"
if [ "$coverage" = "1" ]; then
  mkdir -p "$covdir"
fi

# Collect the test files: explicit .vibe files, or every *_test.vibe under a dir.
#
# The expansion is CHECKED, not trusted (#2870). `find | sort` runs two system
# binaries, and a broken one exits non-zero with an empty stdout -- which the
# loop below cannot tell from "this directory holds no tests", so the run ended
# at `no test files found` and reported it as an ordinary outcome. Measured
# 2026-09-18: with `LD_LIBRARY_PATH` set to the nix store path the `pkf`
# wrapper exports, `/usr/bin/sort` dies on `GLIBC_ABI_DT_X86_64_PLT not found`
# and a directory holding one test file expands to nothing. "Could not decide"
# and "nothing to do" must not be the same answer (AGENTS.md).
#
# The status comes through a sentinel line rather than PIPESTATUS: the pipeline
# runs in a process substitution, so its status is not the shell's to read.
files=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    vt_scan_ok=0
    while IFS= read -r f; do
      if [ "$f" = "__vt_scan_ok__" ]; then vt_scan_ok=1; continue; fi
      files+=("$f")
    done \
      < <(find "$arg" -type f -name '*_test.vibe' | sort && echo "__vt_scan_ok__")
    if [ "$vt_scan_ok" != 1 ]; then
      echo "vibe_test.sh: could not list *_test.vibe under $arg (find|sort failed); this is not the same as finding none" >&2
      exit 2
    fi
  elif [ -f "$arg" ]; then
    files+=("$arg")
  else
    echo "vibe_test.sh: not found: $arg" >&2
    exit 2
  fi
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "vibe_test.sh: no test files found" >&2
  exit 2
fi

# Parallel execution (CI bottleneck): each file compiles to its own
# _build/vibe_test/<flat>.wasm and coverage JSON, and the shared persistent
# caches are concurrency-safe (the host runner writes them via temp+rename),
# so files fan out over VIBE_TEST_JOBS workers (default min(4, nproc); the
# heavy compiler tests peak at a few GB each, so unbounded -P would OOM small
# runners). -P 1 degrades to the exact sequential order. Per-file results are
# recorded under a temp dir and aggregated after the fan-out.
vt_hw_jobs="$(nproc 2>/dev/null || echo 1)"
[ "$vt_hw_jobs" -gt 4 ] && vt_hw_jobs=4
VT_JOBS="${VIBE_TEST_JOBS:-$vt_hw_jobs}"
# #2886: --update REWRITES source files, and a worker's patch-and-retry
# recompiles. Running that fan-out would have several processes writing the
# shared persistent build cache while sources move underneath it, and would
# interleave the per-file retry output. Serialize, as runtime/vibe does.
[ "$update" = "1" ] && VT_JOBS=1
export coverage update backend cli_wasm covdir vt_results

# #948: count the lowered `__test_<name>` functions in a compiled test wasm.
# Prefer a real name-section parse (a raw `grep -c __test_` double-counts under
# --coverage, whose instrumentation embeds the names again in a data segment);
# fall back to the grep occurrence count when python3 is unavailable — exact
# for zero-vs-nonzero, which is all the "no tests found" note needs.
vt_count_tests() {
  local wasm="$1" n=""
  if command -v python3 >/dev/null 2>&1; then
    n="$(python3 - "$wasm" 2>/dev/null <<'PY' || true
import sys
b = open(sys.argv[1], "rb").read()
def uleb(i):
    r = s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7F) << s
        if not (x & 0x80):
            return r, i
        s += 7
i, count = 8, 0
while i < len(b):
    sid = b[i]; i += 1
    size, i = uleb(i)
    end = i + size
    if sid == 0:
        nlen, j = uleb(i)
        if b[j:j + nlen] == b"name":
            j += nlen
            while j < end:
                subid = b[j]; j += 1
                ssize, j = uleb(j)
                send = j + ssize
                if subid == 1:  # function-name subsection
                    cnt, k = uleb(j)
                    for _ in range(cnt):
                        _, k = uleb(k)
                        ln, k = uleb(k)
                        if b[k:k + ln].startswith(b"__test_"):
                            count += 1
                        k += ln
                j = send
    i = end
print(count)
PY
)"
  fi
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  # No name section (the gc backend strips it) or no python3: fall back to the
  # raw occurrence count (exports/data still carry the `__test_` strings).
  if [ -z "$n" ] || [ "$n" = "0" ]; then
    local g
    g="$({ grep -ao '__test_' "$wasm" 2>/dev/null || true; } | wc -l | tr -d '[:space:]')"
    case "$g" in ''|*[!0-9]*) g=0 ;; esac
    if [ "$g" -gt 0 ] || [ -z "$n" ]; then n="$g"; fi
  fi
  printf '%s' "$n"
}
export -f vt_count_tests

# #2886 `--update`: patch a failing file's stale `inspect(value, content)`
# literals to the values this run actually printed, then let the caller
# recompile and re-run. The patch itself is done by the COMPILER, through
# cli_main's VIBE_INSPECT_UPDATE adapter mode -- the same mode `runtime/vibe`
# drives behind its `inspect-update` verb, so there is one implementation of
# "what does this diagnostic mean" and this script only moves files around.
#
# It runs against "$cli_wasm", i.e. the same compiler that produced the
# failing output. That is the reason the flag belongs here at all: CLAUDE.md
# routes a compiler change through this script because it is the only lane
# that honours VIBE_TEST_CLI_WASM, and a snapshot updated by a DIFFERENT
# compiler than the one under test records the wrong answer (the "which
# compiler answered?" failure, in its most durable form -- committed).
#
# Returns 0 only when the source file actually changed. An unrecognized
# mismatch, or a literal an earlier iteration already patched, makes the
# adapter write the input back unchanged; calling that progress would spin
# until the depth bound with nothing to show. The adapter reads and writes
# through the wasm preopen, so both scratch paths are repo-relative.
# $1 = repo-relative source path, $2 = flat name, $3 = the run's captured output.
vt_try_update_patch() {
  local src_rel="$1" flat="$2" captured="$3"
  local cap_rel="_build/vibe_test/$flat.captured"
  local pat_rel="_build/vibe_test/$flat.patched"
  [ -s "$captured" ] || return 1
  rm -f "$ROOT_DIR/$pat_rel"
  cp "$captured" "$ROOT_DIR/$cap_rel" || return 1
  if ! env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_INSPECT_UPDATE=1       VIBE_INSPECT_UPDATE_STDOUT="$cap_rel" VIBE_IMPORT_ABI=raw       bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"       --invoke cli_main "$cli_wasm" "$src_rel" "$pat_rel" >/dev/null 2>&1; then
    rm -f "$ROOT_DIR/$cap_rel" "$ROOT_DIR/$pat_rel"
    return 1
  fi
  # An empty output is a failed patch, not an empty program: never truncate a
  # source file on it.
  if [ ! -s "$ROOT_DIR/$pat_rel" ] || cmp -s "$ROOT_DIR/$pat_rel" "$ROOT_DIR/$src_rel"; then
    rm -f "$ROOT_DIR/$cap_rel" "$ROOT_DIR/$pat_rel"
    return 1
  fi
  cp "$ROOT_DIR/$pat_rel" "$ROOT_DIR/$src_rel" || return 1
  rm -f "$ROOT_DIR/$cap_rel" "$ROOT_DIR/$pat_rel"
  return 0
}
export -f vt_try_update_patch

# $1 = one `<src_rel><TAB><flat>` line of the run's entries: the spelling
# @vibe/testrun gave the path (#3505) and the artifact name it maps to.
vt_worker() {
  local entry="$1" src_rel flat
  src_rel="${entry%%$'\t'*}"
  flat="${entry#*$'\t'}"
  local out_rel="_build/vibe_test/$flat.wasm"
  local cov_out=""
  if [ "$coverage" = "1" ]; then
    cov_out="$covdir/$flat.json"
    # A successful run must produce coverage for this invocation. Without
    # clearing first, a compiler/runner regression can make an old report look
    # fresh and let a coverage gate pass without measuring anything (#2153).
    rm -f "$cov_out"
  fi

  # Compile with a sentinel entry name that does not exist in the file, so the
  # compiler takes the no-entry path and emits a test-running `_start`.
  # VIBE_COVERAGE=$coverage selects the instrumented codegen when --coverage.
  # Backend selection is independent from filesystem module loading: both
  # lanes resolve imports, while VIBE_BACKEND selects only the final codegen.
  local compile_env
  if [ "$backend" = "gc" ]; then
    compile_env=(VIBE_FS_COMPILE=1 VIBE_BACKEND=gc)
  else
    compile_env=(VIBE_FS_COMPILE=1)
  fi
  if ! env VIBE_COVERAGE="$coverage" VIBE_PREOPEN_DIR="$ROOT_DIR" "${compile_env[@]}" VIBE_IMPORT_ABI=raw \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main "$cli_wasm" "$src_rel" "$out_rel" "__no_entry__" \
      >/dev/null 2>&1 || [ ! -s "$ROOT_DIR/$out_rel" ]; then
    # #948: the line carries the compiler's diagnostic from the `<out>.diag`
    # sidecar instead of a bare FAIL. Each per-file block is printed in ONE
    # write, so parallel workers cannot interleave inside it.
    local shown
    shown="$(vt_tool compile-fail "$src_rel" "$ROOT_DIR/$out_rel.diag" "$vt_results/$flat.res")"
    printf '%s\n' "$shown"
    return 0
  fi

  # #948: count the file's lowered `__test_<name>` functions (wasm name
  # section) so a file whose test blocks were never recognized is flagged
  # instead of silently passing as an empty `_start`. Zero tests keeps exit 0
  # (an annotated ok, not a failure) so suites with helper-only files survive.
  # The gc backend strips every `__test_` name from its wasm, so the count is
  # unknowable there — leave it empty (no note, legacy summary).
  local n_tests=""
  if [ "$backend" != "gc" ]; then
    n_tests="$(vt_count_tests "$ROOT_DIR/$out_rel")"
  fi

  # #948: keep the runner's stderr — it names the failing `__test_` function
  # (previously discarded, leaving a bare `FAIL <file>` with no test name).
  local run_ok=0
  # #2886: stdout is kept SEPARATELY as well. `inspect` prints its mismatch
  # diagnostic to stdout, and the compiler's snapshot patcher reads the
  # "expected:" value as everything that follows -- a snapshot may contain
  # newlines. Handing it the merged stream makes the wasm trap's stack frames
  # part of the expected value, which then matches no literal in the file and
  # the patch silently no-ops. The report reads both captures separately so
  # runtime-looking snapshot lines cannot masquerade as a runner trap.
  local run_out="$vt_results/$flat.out"
  local run_errf="$vt_results/$flat.err2"
  if [ "$backend" = "gc" ]; then
    if run_bounded 60 wasmtime run -W gc=y,function-references=y,exceptions=y \
        --invoke _start "$ROOT_DIR/$out_rel" >"$run_out" 2>"$run_errf"; then
      run_ok=1
    fi
  else
    if VIBE_COV_OUT="$cov_out" VIBE_PREOPEN_DIR="$ROOT_DIR" \
        bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
        --invoke _start "$out_rel" >"$run_out" 2>"$run_errf"; then
      run_ok=1
    fi
  fi
  if [ "$run_ok" = "1" ]; then
    # A --coverage pass needs a fresh report (one cleared above, #2153);
    # VIBE_COV_SHOW_GAPS=1 also lists what it did not reach.
    local shown
    if [ "$coverage" = "1" ]; then
      shown="$(vt_tool coverage "$src_rel" "$cov_out" "$n_tests" "${VIBE_COV_SHOW_GAPS:-0}" "$vt_results/$flat.res")"
    else
      shown="$(vt_tool pass "$src_rel" "$n_tests" "${VIBE_TEST_UPDATE_PATCHES:-0}" "$vt_results/$flat.res")"
    fi
    printf '%s\n' "$shown"
    rm -f "$run_out" "$run_errf"
  else
    # #2886 `--update`: before reporting, try to bring the file's stale
    # inspect() snapshots up to date and run it again. The re-run re-enters
    # this worker, so it recompiles -- a patched literal changes the program,
    # and reporting a pass from the wasm built before the patch would be a
    # green that does not correspond to any source on disk. The depth bound
    # (same 50 as runtime/vibe) stops a file whose inspect() calls can never
    # all agree at once from looping forever.
    local _depth="${VIBE_TEST_UPDATE_DEPTH:-0}"
    if [ "$update" = "1" ] && [ "$_depth" -lt 50 ] \
        && vt_try_update_patch "$src_rel" "$flat" "$run_out"; then
      rm -f "$run_out" "$run_errf"
      VIBE_TEST_UPDATE_DEPTH=$((_depth + 1)) \
        VIBE_TEST_UPDATE_PATCHES=$((${VIBE_TEST_UPDATE_PATCHES:-0} + 1)) \
        vt_worker "$entry"
      return 0
    fi
    # #948: FAIL, then the condensed report (@vibe/testreport), in ONE write;
    # the report's lines are indented, so `^(ok|FAIL) <file>` parsers
    # (coverage_suite.sh) are unaffected. A file --update rewrote that still
    # fails says so (#2886).
    local shown
    shown="$(vt_tool fail "$src_rel" "$n_tests" "${VIBE_TEST_UPDATE_PATCHES:-0}" "$run_out" "$run_errf" \
      "$ROOT_DIR/$out_rel.funcmap" "$(basename "$src_rel")" "$ROOT_DIR/$src_rel" "$vt_results/$flat.res")"
    printf '%s\n' "$shown"
    rm -f "$run_out" "$run_errf"
  fi
  return 0
}
export -f vt_worker

# Tests that INSPECT the shared persistent-cache state (.vibe/build/cache/vibe_*) cannot
# run while other workers' compiles are writing it -- the cache-file
# counts/contents they assert on shift underneath them (same split as
# unit_test_runner.sh). Anything with "cache" in its path runs in a
# sequential tail after the fan-out instead.
# One `<src_rel><TAB><flat>` line per file the run compiles; a path outside
# the repository is reported and recorded by the tool instead.
vt_tool entries "$ROOT_DIR" "$vt_results" "${files[@]}" > "$vt_results/entries.tsv"
grep -vi cache "$vt_results/entries.tsv" \
  | xargs -P "$VT_JOBS" -I{} bash -c 'vt_worker "$@"' _ {} || true
while IFS= read -r f; do
  [ -n "$f" ] && vt_worker "$f"
done < <(grep -i cache "$vt_results/entries.tsv" || true)

# The `[vibe-test]` lines (#948: the test-block total beside the per-file
# counts; the gc backend strips the names, so it keeps the files-only line),
# the seed note after a compile failure, and the coverage totals. The tool's
# status is the run's: 1 when any file failed.
vt_seed_default=0
[ -z "${VIBE_TEST_CLI_WASM:-}" ] && vt_seed_default=1
vt_status=0
vt_tool summary "$vt_results" "${#files[@]}" "$coverage" "$vt_seed_default" "$seed" "$covdir" || vt_status=$?
exit "$vt_status"
