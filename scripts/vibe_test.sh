#!/usr/bin/env bash
# Selfhost `vibe test` (#594): compile a .vibe test file (resolving imports from
# the filesystem) with the committed seed compiler, then execute it via the Rust
# runner — no MoonBit host.
#
#   bash scripts/vibe_test.sh [--coverage] <path.vibe | dir> [more paths...]
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Parse flags (only --coverage today); leave the rest as positional paths.
coverage=0
_args=()
for _a in "$@"; do
  if [ "$_a" = "--coverage" ]; then
    coverage=1
  else
    _args+=("$_a")
  fi
done
set -- ${_args[@]+"${_args[@]}"}

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_test.sh [--coverage] <path.vibe | dir> [more paths...]" >&2
  exit 2
fi

bash "$ROOT_DIR/scripts/ensure_seed.sh"
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
outdir="$ROOT_DIR/_build/vibe_test"
mkdir -p "$outdir"

# #683: VIBE_TEST_BACKEND=gc compiles each test file on the wasm-gc backend
# (VIBE_BACKEND=gc, direct single-file compile — no FS import resolution) and
# runs it under wasmtime with the gc feature flags instead of the node host
# runner. Self-contained *_test.vibe files only; files with imports fail to
# compile on this lane. Not combinable with --coverage (linear-only
# instrumentation).
backend="${VIBE_TEST_BACKEND:-linear}"
if [ "$backend" = "gc" ] && [ "$coverage" = "1" ]; then
  echo "vibe_test.sh: --coverage is linear-backend only (unset VIBE_TEST_BACKEND=gc)" >&2
  exit 2
fi
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
files=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find "$arg" -type f -name '*_test.vibe' | sort)
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
vt_results="$(mktemp -d -t vibe-test-results-XXXXXX)"
export ROOT_DIR coverage backend cli_wasm covdir vt_results

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

# #948: condense a failed run's captured stderr into indented detail lines.
# The raw stream is a full node/V8 (or wasmtime) trap dump; the useful signal is
#   * the `__test_<name>` frame  -> which test failed,
#   * the trap reason line       -> why (RuntimeError / wasm trap ...),
#   * the wasm frames            -> where (annotated file:line via the
#     `<out>.funcmap` sidecar the FS compile already writes, same as `vibe run`).
# Lines are indented so they can never collide with the `ok`/`FAIL` per-file
# lines that coverage_suite.sh & friends parse.
#   $1 = stderr capture file, $2 = funcmap path (may be missing), $3 = source basename
vt_fail_detail() {
  local errf="$1" fm="$2" base="$3"
  [ -s "$errf" ] || return 0
  awk -v base="$base" -v fmfile="$fm" '
    function hexval(c) {
      if (c >= "0" && c <= "9") return c + 0
      if (c >= "A" && c <= "F") return index("ABCDEF", c) + 9
      if (c >= "a" && c <= "f") return index("abcdef", c) + 9
      return -1
    }
    # Quoted names may appear percent-encoded (`has%20spaces`). Keep
    # this decoder in lockstep with runtime/vibe condense_test_trap.
    function pct_decode(s,    out, i, n, c, v1, v2) {
      out = ""
      n = length(s)
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "%" && i + 2 <= n) {
          v1 = hexval(substr(s, i + 1, 1))
          v2 = hexval(substr(s, i + 2, 1))
          if (v1 >= 0 && v2 >= 0) {
            out = out sprintf("%c", v1 * 16 + v2)
            i += 3
            continue
          }
        }
        out = out c
        i++
      }
      return out
    }
    BEGIN {
      if (fmfile != "") {
        while ((getline l < fmfile) > 0) {
          n = split(l, a, "\t")
          if (n >= 2 && a[1] != "" && a[2]+0 > 0) fmln[a[1]] = a[2]+0
        }
        close(fmfile)
      }
    }
    # First __test_<name> stack frame = the failing test. Quoted names
    # keep spaces and Unicode in the wasm name section; some frames
    # percent-encode those bytes (`has%20spaces`). Cut at the frame
    # delimiter (` (wasm:` on Node/V8, EOL on wasmtime), not at the
    # first non-[A-Za-z0-9_%] character (#1946). Guest stderr can
    # contain `__test_` (e.g. `__test_!!!`); only Node `at ... (wasm:`
    # and wasmtime `<unknown>!` frames count.
    !seen_test && match($0, /at __test_/) {
      rest = substr($0, RSTART + length("at __test_"))
      if (match(rest, / \(wasm:/)) {
        failing = substr(rest, 1, RSTART - 1)
        if (failing != "") seen_test = 1
      }
    }
    !seen_test && match($0, /<unknown>!__test_/) {
      failing = substr($0, RSTART + length("<unknown>!__test_"))
      sub(/[[:space:]]+$/, "", failing)
      if (failing != "") seen_test = 1
    }
    # Assert-abort recognizer (#2202). Suppressing the trailing trap must not
    # trust arbitrary captured output that happens to contain these lines (a
    # test can println them and then hit a REAL unrelated trap): it requires a
    # COMPLETE consecutive failed/expected/actual block, followed by the trap
    # reason with only the host crash-debug dump or blank lines in between --
    # the exact shape the generated assert_eq abort produces.
    { __blk = 0 }
    $0 == "assert_eq failed" {
      __blk = 1
      ablk = 1
      ndiag++
      diags[ndiag] = "       " $0
    }
    $0 ~ /^  expected:/ {
      __blk = 1
      if (ablk == 1) ablk = 2
      ndiag++
      diags[ndiag] = "       " $0
    }
    $0 ~ /^  actual:/ {
      __blk = 1
      if (ablk == 2) ablk = 3
      ndiag++
      diags[ndiag] = "       " $0
    }
    # #2199: an OOB abort prints its operation plus the index and length
    # before trapping; keep that line in the condensed report -- it is the
    # whole explanation of the trap that follows. The full-line anchored
    # match (fixed operation names, decimal index, decimal length) keeps
    # ordinary program output from masquerading as a runtime diagnostic.
    # Deliberately NOT marked __blk: it is not part of an assert diagnostic,
    # so it must still break assert-abort adjacency like any other output.
    $0 ~ /^(Array::get|Array::set|Bytes::get|Bytes::set|String::byte_at): index -?[0-9]+ out of bounds for length [0-9]+$/ {
      ndiag++
      diags[ndiag] = "       " $0
    }
    # The closing line the generated assert_eq abort prints (lower_assert_eq
    # in normalize/desugar_trait_dict.vibe): the definitive signal, immune to
    # multiline rendered values and to output that imitates the block. Hidden
    # from the report (the block above already told the story). The
    # consecutive-block recognizer stays for tests compiled by a seed that
    # predates the marker.
    $0 == "assert failed: aborting" {
      __blk = 1
      pending_abort = 1
    }
    # First trap-reason line (backtrace frames never contain these markers;
    # strip anyhow chain numbering / runner prefixes).
    !seen_reason && /RuntimeError:|wasm trap:/ {
      __blk = 1
      seen_reason = 1
      assert_abort = (ablk == 3 || pending_abort == 1)
      reason = $0
      sub(/^[[:space:]]+/, "", reason)
      sub(/^[0-9]+: /, "", reason)
      sub(/^viberun: /, "", reason)
    }
    # Any other non-blank, non-crash-debug line between the block/marker and
    # the trap breaks the adjacency: the trap is then not the assert abort.
    !seen_reason && __blk == 0 && $0 != "" && $0 !~ /^\[crash debug\]/ {
      ablk = 0
      pending_abort = 0
    }
    # Wasm backtrace frames (node: `at <fn> (wasm://...)`, wasmtime:
    # `N: 0x.. - <unknown>!<fn>`), capped, annotated via the funcmap.
    nframes < 6 {
      fn = ""
      if (match($0, /^[[:space:]]+at [A-Za-z0-9_$.]+ \(wasm:/)) {
        fn = $0; sub(/^[[:space:]]+at /, "", fn); sub(/ \(wasm:.*/, "", fn)
      } else if ($0 ~ /<unknown>!/ && match($0, /![A-Za-z0-9_]+/)) {
        fn = substr($0, RSTART + 1, RLENGTH - 1)
      }
      # `__test_*` is reported as the failing test; `_start` is scaffolding.
      if (fn != "" && fn != "_start" && fn !~ /^__test_/) {
        nframes++
        if (fn in fmln) frames[nframes] = "       at " fn " (" base ":" fmln[fn] ")"
        else            frames[nframes] = "       at " fn
      }
    }
    END {
      if (failing != "") print "       failing test: " pct_decode(failing)
      for (i = 1; i <= ndiag; i++) print diags[i]
      # An assert failure aborts via a deliberate `unreachable` trap; once the
      # assert block above already told the story, echoing that trap reads as
      # a second, unexplained failure (#2202). Any OTHER trap -- a different
      # reason, or an unreachable that does not directly follow a complete
      # assert block -- is still real and still printed.
      if (reason != "" && !(assert_abort && reason ~ /unreachable/)) print "       trap: " reason
      for (i = 1; i <= nframes; i++) print frames[i]
    }
  ' "$errf"
}
export -f vt_fail_detail

vt_worker() {
  local src="$1"
  local src_rel
  case "$src" in
    "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
    /*)
      echo "vibe_test.sh: path must be under the repo root: $src" >&2
      printf 'fail 0 0 0 0 0\n' > "$vt_results/$(printf '%s' "$src" | tr '/' '_').res"
      return 0
      ;;
    *) src_rel="$src" ;;
  esac
  local flat; flat="$(echo "$src_rel" | tr '/' '_' | sed 's/\.vibe$//')"
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
  # VIBE_TEST_BACKEND=gc: single-file wasm-gc compile (no VIBE_FS_COMPILE).
  local compile_env
  if [ "$backend" = "gc" ]; then
    compile_env=(VIBE_BACKEND=gc)
  else
    compile_env=(VIBE_FS_COMPILE=1)
  fi
  if ! env VIBE_COVERAGE="$coverage" VIBE_PREOPEN_DIR="$ROOT_DIR" "${compile_env[@]}" VIBE_IMPORT_ABI=raw \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main "$cli_wasm" "$src_rel" "$out_rel" "__no_entry__" \
      >/dev/null 2>&1 || [ ! -s "$ROOT_DIR/$out_rel" ]; then
    # #948: surface the compiler's structured diagnostic (message + location)
    # from the `<out>.diag` sidecar instead of a bare FAIL.
    local cdetail=""
    if [ -s "$ROOT_DIR/$out_rel.diag" ]; then
      cdetail="$(head -1 "$ROOT_DIR/$out_rel.diag")"
    fi
    if [ -n "$cdetail" ]; then
      printf 'FAIL (compile) %s\n       %s\n' "$src_rel" "$cdetail"
    else
      echo "FAIL (compile) $src_rel"
    fi
    printf 'fail 0 0 0 0 0\n' > "$vt_results/$flat.res"
    printf 'seed\n' > "$vt_results/$flat.compilefail"
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
  local run_err="$vt_results/$flat.err"
  if [ "$backend" = "gc" ]; then
    if timeout 60 wasmtime run -W gc=y,function-references=y,exceptions=y \
        --invoke _start "$ROOT_DIR/$out_rel" >"$run_err" 2>&1; then
      run_ok=1
    fi
  else
    if VIBE_COV_OUT="$cov_out" VIBE_PREOPEN_DIR="$ROOT_DIR" \
        bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
        --invoke _start "$out_rel" >"$run_err" 2>&1; then
      run_ok=1
    fi
  fi
  if [ "$run_ok" = "1" ]; then
    if [ "$coverage" = "1" ] && [ -s "$cov_out" ]; then
      local f_hit f_total b_hit b_total
      read -r f_hit f_total b_hit b_total < <(python3 - "$cov_out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
b = r.get("branch") or {}
print(r.get("hit", 0), r.get("total", 0), b.get("hit", 0), b.get("total", 0))
PY
)
      printf 'ok   %s  [cov fn %d/%d, branch %d/%d]\n' "$src_rel" "$f_hit" "$f_total" "$b_hit" "$b_total"
      if [ "${VIBE_COV_SHOW_GAPS:-0}" = "1" ]; then
        # Surface WHAT is uncovered (the CLI summary alone is not actionable):
        # never-called functions and functions with untaken if/match branches.
        python3 - "$cov_out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
missed = r.get("missed_fns", [])
if missed:
    print("       uncovered functions: " + ", ".join(missed))
for g in (r.get("branch") or {}).get("top_gaps", []):
    print(f"       branch gap: {g['fn']} {g['taken']}/{g['total']} taken")
PY
      fi
      printf 'ok %s %s %s %s 1 %s\n' "$f_hit" "$f_total" "$b_hit" "$b_total" "$n_tests" > "$vt_results/$flat.res"
    elif [ "$coverage" = "1" ]; then
      echo "FAIL (coverage) $src_rel"
      echo "       test passed but produced no fresh coverage report: $cov_out"
      printf 'fail 0 0 0 0 0 %s\n' "$n_tests" > "$vt_results/$flat.res"
    else
      # #948: annotate (don't fail) a file with zero recognized `test {}`
      # blocks — a typo'd block otherwise passes silently via an empty _start.
      if [ "$n_tests" = "0" ]; then
        echo "ok   $src_rel (no tests found)"
      else
        echo "ok   $src_rel"
      fi
      printf 'ok 0 0 0 0 0 %s\n' "$n_tests" > "$vt_results/$flat.res"
    fi
    rm -f "$run_err"
  else
    # #948: FAIL + condensed detail in ONE write so parallel workers cannot
    # interleave inside the block; detail lines are indented, so downstream
    # `^(ok|FAIL) <file>` parsers (coverage_suite.sh) are unaffected.
    local detail
    detail="$(vt_fail_detail "$run_err" "$ROOT_DIR/$out_rel.funcmap" "$(basename "$src_rel")")"
    if [ -n "$detail" ]; then
      printf 'FAIL %s\n%s\n' "$src_rel" "$detail"
    else
      echo "FAIL $src_rel"
    fi
    printf 'fail 0 0 0 0 0 %s\n' "$n_tests" > "$vt_results/$flat.res"
    rm -f "$run_err"
  fi
  return 0
}
export -f vt_worker

# Tests that INSPECT the shared persistent-cache state (_build/vibe_*) cannot
# run while other workers' compiles are writing it -- the cache-file
# counts/contents they assert on shift underneath them (same split as
# unit_test_runner.sh). Anything with "cache" in its path runs in a
# sequential tail after the fan-out instead.
printf '%s\n' "${files[@]}" | grep -vi cache \
  | xargs -P "$VT_JOBS" -I{} bash -c 'vt_worker "$@"' _ {} || true
while IFS= read -r f; do
  [ -n "$f" ] && vt_worker "$f"
done < <(printf '%s\n' "${files[@]}" | grep -i cache)

pass=0
fail=0
tests_total=0
notest_files=0
cov_fn_total=0
cov_fn_hit=0
cov_br_total=0
cov_br_hit=0
cov_files=0
for res in "$vt_results"/*.res; do
  [ -f "$res" ] || continue
  read -r r_status r_fh r_ft r_bh r_bt r_cov r_nt < "$res"
  case "${r_nt:-}" in ''|*[!0-9]*) r_nt=0 ;; esac
  tests_total=$((tests_total + r_nt))
  if [ "$r_status" = "ok" ]; then
    pass=$((pass + 1))
    [ "$r_nt" = "0" ] && notest_files=$((notest_files + 1))
    if [ "$r_cov" = "1" ]; then
      cov_fn_hit=$((cov_fn_hit + r_fh)); cov_fn_total=$((cov_fn_total + r_ft))
      cov_br_hit=$((cov_br_hit + r_bh)); cov_br_total=$((cov_br_total + r_bt))
      cov_files=$((cov_files + 1))
    fi
  else
    fail=$((fail + 1))
  fi
done
compile_fails=0
for marker in "$vt_results"/*.compilefail; do
  [ -f "$marker" ] || continue
  compile_fails=$((compile_fails + 1))
done
rm -rf "$vt_results"

# #948: report the test-block total alongside the per-file counts (reporting
# is still per file / all-or-nothing; true per-test pass/fail is a follow-up).
# The gc backend cannot count tests (names stripped) — keep the legacy summary.
if [ "$backend" = "gc" ]; then
  echo "[vibe-test] $pass passed, $fail failed (${#files[@]} files)"
else
  echo "[vibe-test] $pass passed, $fail failed (${#files[@]} files, $tests_total tests)"
  if [ "$notest_files" -gt 0 ]; then
    echo "[vibe-test] note: $notest_files file(s) with no tests found"
  fi
fi
# `FAIL (compile)` from the SEED is ambiguous: the file may be perfectly good
# and merely use something the seed predates. `inspect` is the standing example
# -- #1571 made it import-free by desugaring it in the checker, so every
# `inspect` call in a current, CI-green test file compiles under stage2 and
# reports `unknown name: inspect` under the seed. Reading that line at face
# value costs a debugging session on a file that is not broken.
if [ "$compile_fails" -gt 0 ] && [ -z "${VIBE_TEST_CLI_WASM:-}" ]; then
  echo "[vibe-test] note: compiled with the committed seed ($seed)."
  echo "[vibe-test]       A file that uses anything newer than the seed fails here even when it is correct."
  echo "[vibe-test]       Re-check against this checkout's compiler with:"
  echo "[vibe-test]         VIBE_TEST_CLI_WASM=_build/selfhost/generations/<gen>_\$(git rev-parse --short HEAD)/stage2.wasm"
fi
if [ "$coverage" = "1" ] && [ "$cov_files" -gt 0 ]; then
  fn_pct=$(python3 -c "print(f'{($cov_fn_hit/$cov_fn_total*100):.2f}%' if $cov_fn_total else 'n/a')")
  br_pct=$(python3 -c "print(f'{($cov_br_hit/$cov_br_total*100):.2f}%' if $cov_br_total else 'n/a')")
  echo "[vibe-test] coverage: functions $cov_fn_hit/$cov_fn_total ($fn_pct), branches $cov_br_hit/$cov_br_total ($br_pct) over $cov_files file(s)"
  echo "[vibe-test] per-file coverage JSON: $covdir/"
fi
[ "$fail" -eq 0 ]
