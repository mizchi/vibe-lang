#!/usr/bin/env bash
# Selfhost unit-test runner (#531 / #535).
#
# Compiles + runs every allowlisted `*_test.vibe` through the selfhost
# compiler. A file PASSES when it compiles (the compiler emits a `_start` that
# runs the file's `test {}` blocks, selected via the `__no_entry__` entry) AND
# that `_start` runs to completion (a failing `assert` traps the module).
#
# This is the regression net for language/stdlib features the compiler itself
# does not exercise during self-build. The retired MoonBit-host suite ran the
# full corpus; the selfhost compiler's prelude/parser is a subset, so we gate
# the allowlisted subset that passes today and ratchet it upward over time
# (#531). New failures in any allowlisted file fail the run (and CI).
#
# Modes:
#   (default)            run the allowlist; exit non-zero if any file fails
#   --list               print the allowlist and exit
#   --scan               compile+run EVERY discovered *_test.vibe, print a full
#                        pass/fail report + any allowlist drift, then exit 0
#   --update-allowlist   rescan all *_test.vibe and overwrite the allowlist with
#                        the passing set (run after intentionally widening it)
#
# Stage2 selection: reuse $VIBE_STAGE2_WASM when set and non-empty
# (CI reuses the gate's freshly-built stage2 to avoid a second selfbuild);
# otherwise build a fresh seed->stage1->stage2 generation and use its stage2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

ALLOWLIST="${VIBE_UNIT_TEST_ALLOWLIST:-$ROOT_DIR/scripts/unit_test_allowlist.txt}"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

mode="run"
case "${1:-}" in
  --list) mode="list" ;;
  --scan) mode="scan" ;;
  --update-allowlist) mode="update" ;;
  "") mode="run" ;;
  *) echo "unknown argument: $1 (expected --list|--scan|--update-allowlist)" >&2; exit 2 ;;
esac

if [ "$mode" = "list" ]; then
  cat "$ALLOWLIST"
  exit 0
fi

# --- obtain a stage2 compiler -------------------------------------------------
S2=""
if [ -n "${VIBE_STAGE2_WASM:-}" ] && [ -s "${VIBE_STAGE2_WASM}" ]; then
  S2="$VIBE_STAGE2_WASM"
  echo "[unit-test-runner] using prebuilt stage2: $S2"
else
  outdir="$ROOT_DIR/_build/_unit_test_gen"
  echo "[unit-test-runner] building fresh stage2 (seed->stage1->stage2)"
  rm -f "$ROOT_DIR"/_build/vibe_selfhost_*.tsv
  bash scripts/generations.sh build --out-dir "$outdir" >/dev/null
  S2="$outdir/stage2.wasm"
fi
[ -s "$S2" ] || { echo "[unit-test-runner] FAIL: no stage2 compiler available" >&2; exit 1; }

# --- local HTTP echo server (#794) --------------------------------------------
# lib/@vibe/http/http_e2e_test.vibe drives real HTTP against
# tests/http_echo_server.py. Detection is content-based (the env-override
# marker / endpoint string in the test source), like the wasmtime gate below.
# If python3 is unavailable the server is not started and the affected tests
# fail with a connection error -- an honest signal, not a silent skip.
#
# #934: the port is derived from the repo path (18280 + hash % 1000) so
# concurrent batteries in different worktrees each own a private server
# instead of colliding on a fixed 18280 (where the first battery to finish
# killed the shared server out from under the other). The test reads the
# port from VIBE_HTTP_ECHO_PORT, exported below for the compiled test runs.
http_echo_pid=""
http_echo_port="${VIBE_HTTP_ECHO_PORT:-$((18280 + $(printf '%s' "$ROOT_DIR" | cksum | cut -d' ' -f1) % 1000))}"
export VIBE_HTTP_ECHO_PORT="$http_echo_port"
start_http_echo_server_if_needed() {
  local list_file="$1"
  local need=0 f
  while IFS= read -r f; do
    case "$f" in ''|\#*) continue ;; esac
    if [ -f "$f" ] && grep -q "VIBE_HTTP_ECHO_PORT\|127.0.0.1:18280" "$f"; then need=1; break; fi
  done < "$list_file"
  [ "$need" -eq 1 ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$ROOT_DIR/tests/http_echo_server.py" ] || return 0
  python3 "$ROOT_DIR/tests/http_echo_server.py" "$http_echo_port" >/dev/null 2>&1 &
  http_echo_pid=$!
  trap 'if [ -n "$http_echo_pid" ]; then kill "$http_echo_pid" 2>/dev/null || true; fi' EXIT
  sleep 1
  if ! kill -0 "$http_echo_pid" 2>/dev/null; then
    echo "[unit-test-runner] WARN: http echo server failed to start on 127.0.0.1:$http_echo_port" >&2
    echo "[unit-test-runner] WARN: (port in use? another battery in the SAME worktree would collide)" >&2
    http_echo_pid=""
    return 0
  fi
  echo "[unit-test-runner] started http echo server (pid $http_echo_pid, 127.0.0.1:$http_echo_port)"
}

# --- compile + run one test file; 0 = pass, 1 = fail --------------------------
# A heavy file can trap the compiler with no diagnostic (the bump-heap hits a
# guard page mid-compile) — that's a nondeterministic heap-marginal OOM, not a
# regression, so retry it. Deterministic failures are NOT retried: a real
# compile error writes a `.diag` sidecar, and a failing test assert traps at
# runtime — both are stable, so the first observation is final.
run_one() {
  local f="$1"
  local attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    local out; out="$(mktemp -t vibe-unit-XXXXXX.wasm)"
    rm -f "$out" "$out.diag"
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      timeout 300 bash "$RUNNER" --invoke cli_main "$S2" "$f" "$out" __no_entry__ >/dev/null 2>&1 || true
    if [ -s "$out" ]; then
      # timeout: a miscompiled test that loops forever must fail the FILE,
      # not hang the whole battery (a nested-loop break-depth bug once
      # spun a single _start for an hour with no per-test bound).
      if VIBE_PREOPEN_DIR="$ROOT_DIR" timeout 120 bash "$RUNNER" --invoke _start "$out" >/dev/null 2>&1; then
        rm -f "$out" "$out.diag"; return 0
      fi
      LAST_DIAG="(test assertion trapped at runtime)"
      rm -f "$out" "$out.diag"; return 1
    fi
    if [ -s "$out.diag" ]; then
      LAST_DIAG="$(cat "$out.diag" 2>/dev/null | head -1)"
      rm -f "$out" "$out.diag"; return 1
    fi
    # No wasm and no diagnostic = compiler trapped (heap-marginal). Retry.
    LAST_DIAG="(compile trapped with no diagnostic — heap-marginal, $attempt/3)"
    rm -f "$out" "$out.diag"
  done
  return 1
}

discover() { find examples lib -name '*_test.vibe' 2>/dev/null | sed "s@^$ROOT_DIR/@@" | sed 's@^\./@@' | sort; }

# --- --scan / --update-allowlist: rescan everything ---------------------------
if [ "$mode" = "scan" ] || [ "$mode" = "update" ]; then
  discovered="$(mktemp)"; discover > "$discovered"
  start_http_echo_server_if_needed "$discovered"
  rm -f "$discovered"
  passing="$(mktemp)"; : > "$passing"
  npass=0; nfail=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if run_one "$f"; then
      echo "$f" >> "$passing"; npass=$((npass+1))
    else
      nfail=$((nfail+1))
      [ "$mode" = "scan" ] && echo "  fail: $f -- ${LAST_DIAG:-}"
    fi
  done < <(discover)
  echo "[unit-test-runner] scan: PASS=$npass FAIL=$nfail"
  if [ "$mode" = "update" ]; then
    {
      echo "# Selfhost unit-test runner allowlist (#531 / #535)."
      echo "# Every *_test.vibe here compiles + runs clean through the selfhost"
      echo "# compiler. Regenerate after widening: scripts/unit_test_runner.sh --update-allowlist"
      echo "# Ratchet target: the full *_test.vibe corpus as the selfhost prelude/parser grows."
      cat "$passing"
    } > "$ALLOWLIST"
    echo "[unit-test-runner] wrote $(wc -l < "$passing") entries to $ALLOWLIST"
  else
    # Report drift vs the committed allowlist (informational; --scan never fails).
    comm -13 <(grep -vE '^\s*#' "$ALLOWLIST" | sed '/^$/d' | sort) <(sort "$passing") > "$ROOT_DIR/_build/.unit_newpass" || true
    if [ -s "$ROOT_DIR/_build/.unit_newpass" ]; then
      echo "[unit-test-runner] newly-passing (not yet in allowlist — consider --update-allowlist):"
      sed 's/^/  + /' "$ROOT_DIR/_build/.unit_newpass"
    fi
    rm -f "$ROOT_DIR/_build/.unit_newpass"
  fi
  rm -f "$passing"
  exit 0
fi

# --- default: run the allowlist, fail on any regression -----------------------
[ -f "$ALLOWLIST" ] || { echo "[unit-test-runner] FAIL: allowlist not found: $ALLOWLIST" >&2; exit 1; }

# --- shard selection (CI wall-time, 2026-07) -----------------------------------
# VIBE_UNIT_TEST_SHARD="i/N" (0-based) runs only the i-th of N weight-balanced
# partitions, so CI can fan the battery across parallel matrix jobs. Per-file
# cost is extremely skewed (a dozen 30-80s compiles next to hundreds of <1s
# ones), so plain round-robin would leave one shard 3-4x slower than the rest;
# instead entries are LPT-assigned (heaviest first onto the least-loaded
# shard) using the recorded weights in scripts/unit_test_weights.tsv
# (total ms per file; regenerate procedure in that file's header). Files
# missing from the weights table get a median-ish default so new tests don't
# unbalance anything. The assignment is deterministic for a fixed
# (allowlist, weights, N): the union of all N shards is exactly the full
# battery and shards are disjoint.
WEIGHTS="${VIBE_UNIT_TEST_WEIGHTS:-$ROOT_DIR/scripts/unit_test_weights.tsv}"
effective_entries="$(mktemp -t vibe-unit-entries-XXXXXX)"
grep -vE '^[[:space:]]*#' "$ALLOWLIST" | sed '/^[[:space:]]*$/d' > "$effective_entries"
if [ -n "${VIBE_UNIT_TEST_SHARD:-}" ]; then
  case "$VIBE_UNIT_TEST_SHARD" in
    */*) : ;;
    *) echo "[unit-test-runner] FAIL: VIBE_UNIT_TEST_SHARD must be i/N (e.g. 0/3)" >&2; exit 2 ;;
  esac
  shard_i="${VIBE_UNIT_TEST_SHARD%%/*}"
  shard_n="${VIBE_UNIT_TEST_SHARD##*/}"
  if ! [ "$shard_i" -ge 0 ] 2>/dev/null || ! [ "$shard_n" -ge 1 ] 2>/dev/null || [ "$shard_i" -ge "$shard_n" ]; then
    echo "[unit-test-runner] FAIL: bad shard spec: $VIBE_UNIT_TEST_SHARD" >&2; exit 2
  fi
  sharded="$(mktemp -t vibe-unit-shard-XXXXXX)"
  awk -F'\t' -v i="$shard_i" -v n="$shard_n" -v weights="$WEIGHTS" '
    BEGIN {
      while ((getline line < weights) > 0) {
        if (line ~ /^[[:space:]]*(#|$)/) continue
        split(line, a, "\t")
        w[a[1]] = a[2] + 0
      }
      close(weights)
    }
    { files[NR] = $0; wt[NR] = ($0 in w) ? w[$0] : 1500 }
    END {
      # LPT: sort by weight desc (stable by original order), greedy-assign.
      for (k = 1; k <= NR; k++) order[k] = k
      for (a1 = 1; a1 <= NR; a1++)
        for (b1 = a1 + 1; b1 <= NR; b1++)
          if (wt[order[b1]] > wt[order[a1]]) { t = order[a1]; order[a1] = order[b1]; order[b1] = t }
      for (s = 0; s < n; s++) load[s] = 0
      for (k = 1; k <= NR; k++) {
        best = 0
        for (s = 1; s < n; s++) if (load[s] < load[best]) best = s
        load[best] += wt[order[k]]
        if (best == i) print files[order[k]]
      }
    }' "$effective_entries" > "$sharded"
  mv "$sharded" "$effective_entries"
  echo "[unit-test-runner] shard $VIBE_UNIT_TEST_SHARD: $(wc -l < "$effective_entries") of $(grep -cvE '^[[:space:]]*(#|$)' "$ALLOWLIST") allowlisted files"
fi

start_http_echo_server_if_needed "$effective_entries"
# #769: some allowlisted tests shell out to the standalone `wasmtime` CLI
# (wasm_emit_test / codegen_heap_e2e_test run their compiled samples through
# it). CI installs wasmtime (ci.yml), so they are covered there; sandboxes
# without it (Claude/Copilot runners, minimal dev boxes) skip them instead of
# reporting a fake regression. Detection is content-based: a `"wasmtime run`
# string literal in the test source (the sh()/sh_lines() invocation) -- the
# leading quote keeps prose mentions in comments ("...wasmtime runs...") from
# skipping tests that never shell out (fixtures_inline_test was one).
have_wasmtime=0
command -v wasmtime >/dev/null 2>&1 && have_wasmtime=1
total=0; fails=0; skips=0
# Parallelism: the loop is embarrassingly parallel (each file compiles to its
# own mktemp wasm; the persistent caches under _build/vibe_* are safe to share
# because the host runner writes them atomically via temp+rename). Default
# min(4, nproc) -- the heavy compiler tests peak at a few GB of wasm memory
# each, so unbounded -P would OOM small runners. VIBE_UNIT_TEST_JOBS=1 keeps
# the exact sequential behavior (allowlist-ordered output).
hw_jobs="$(nproc 2>/dev/null || echo 1)"
[ "$hw_jobs" -gt 4 ] && hw_jobs=4
JOBS="${VIBE_UNIT_TEST_JOBS:-$hw_jobs}"
if [ "$JOBS" -le 1 ]; then
  while IFS= read -r f; do
    case "$f" in ''|\#*) continue ;; esac
    total=$((total+1))
    if [ ! -f "$f" ]; then
      echo "[unit-test-runner] FAIL: allowlisted file missing on disk: $f" >&2; fails=$((fails+1)); continue
    fi
    if [ "$have_wasmtime" -eq 0 ] && grep -q '"wasmtime run' "$f"; then
      echo "skip: $f (needs the wasmtime CLI; not installed)"
      skips=$((skips+1)); total=$((total-1)); continue
    fi
    if run_one "$f"; then
      echo "ok:   $f"
    else
      echo "FAIL: $f -- ${LAST_DIAG:-}" >&2; fails=$((fails+1))
    fi
  done < "$effective_entries"
else
  echo "[unit-test-runner] running with $JOBS parallel jobs (VIBE_UNIT_TEST_JOBS)"
  results_dir="$(mktemp -d -t vibe-unit-results-XXXXXX)"
  export S2 RUNNER ROOT_DIR results_dir have_wasmtime
  unit_worker() {
    local f="$1"
    local key; key="$(printf '%s' "$f" | tr '/' '_')"
    if [ ! -f "$f" ]; then
      echo "[unit-test-runner] FAIL: allowlisted file missing on disk: $f" >&2
      printf '%s\n' "$f (missing on disk)" > "$results_dir/$key.fail"
      return 0
    fi
    if [ "$have_wasmtime" -eq 0 ] && grep -q '"wasmtime run' "$f"; then
      echo "skip: $f (needs the wasmtime CLI; not installed)"
      : > "$results_dir/$key.skip"
      return 0
    fi
    # Tests that touch persistent-cache state (_build/vibe_*) cannot share
    # the ambient cache with concurrent workers -- the cache-file counts /
    # contents they assert on shift underneath them (persistent_cache_test
    # flaked exactly this way on the first parallel run). They used to run in
    # a sequential tail after the fan-out, but that tail includes the 30-50s
    # cache_probe_* bench compiles and serialized minutes of CI wall time.
    # Instead give each such test a PRIVATE cache root via the
    # VIBE_BUILD_CACHE_DIR override (#849, cache/cache_underlying.vibe) --
    # both the outer stage2 compile of the file and the compiled test's own
    # inner compiles inherit it, so the state they assert on is exclusively
    # theirs and they can join the parallel fan-out. (A handful of tests
    # that assert on the DEFAULT cache-root semantics themselves cannot run
    # under the override -- they stay in a small sequential tail, see
    # strict_cache_tail below.)
    # The private root must live under the repo root: the compiled test runs
    # with VIBE_PREOPEN_DIR=$ROOT_DIR as its only WASI preopen, so a /tmp
    # cache dir would be unreachable from inside the module.
    local iso_cache=""
    if [ "${UNIT_WORKER_NO_ISOLATION:-0}" != "1" ]; then
      case "$f" in
        *[Cc]ache*)
          mkdir -p "$ROOT_DIR/_build"
          iso_cache="$(mktemp -d "$ROOT_DIR/_build/vibe_unit_isocache.XXXXXX")"
          export VIBE_BUILD_CACHE_DIR="$iso_cache"
          ;;
      esac
    fi
    # VIBE_UNIT_TEST_TIME_REPORT=<dir>: record per-file wall ms (compile+run),
    # one file per test to stay atomic under -P. `cat <dir>/* | sort` after a
    # full unsharded run regenerates scripts/unit_test_weights.tsv.
    local t0=0
    [ -n "${VIBE_UNIT_TEST_TIME_REPORT:-}" ] && t0="$(date +%s%N)"
    if run_one "$f"; then
      echo "ok:   $f"
      : > "$results_dir/$key.ok"
    else
      echo "FAIL: $f -- ${LAST_DIAG:-}" >&2
      printf '%s -- %s\n' "$f" "${LAST_DIAG:-}" > "$results_dir/$key.fail"
    fi
    if [ -n "${VIBE_UNIT_TEST_TIME_REPORT:-}" ]; then
      mkdir -p "$VIBE_UNIT_TEST_TIME_REPORT"
      printf '%s\t%s\n' "$f" "$(( ($(date +%s%N) - t0) / 1000000 ))" \
        > "$VIBE_UNIT_TEST_TIME_REPORT/$key.tsv"
    fi
    if [ -n "$iso_cache" ]; then
      unset VIBE_BUILD_CACHE_DIR
      rm -rf "$iso_cache"
    fi
    return 0
  }
  export -f unit_worker run_one
  # strict_cache_tail: tests that assert on the DEFAULT persistent-cache
  # root's own semantics (cache_underlying_env_override_test exercises the
  # VIBE_BUILD_CACHE_DIR override itself; the persistent_* trio asserts
  # default-root invalidation behavior). An ambient VIBE_BUILD_CACHE_DIR
  # breaks them (verified empirically), so they run WITHOUT the override in
  # a short sequential tail after the fan-out -- they total ~5s of compile
  # plus ~40s of run, vs the multi-minute tail the old
  # "everything-matching-cache" rule serialized.
  strict_cache_re='cache_underlying_env_override_test\.vibe$|/persistent_cache_test\.vibe$|loader_persistent_cache_test\.vibe$|persistent_fs_compile_cache_test\.vibe$'
  { grep -vE "$strict_cache_re" "$effective_entries" || true; } \
    | xargs -P "$JOBS" -I{} bash -c 'unit_worker "$@"' _ {}
  while IFS= read -r f; do
    [ -n "$f" ] && UNIT_WORKER_NO_ISOLATION=1 unit_worker "$f"
  done < <(grep -E "$strict_cache_re" "$effective_entries" || true)
  n_ok=$(ls "$results_dir" | grep -c '\.ok$' || true)
  skips=$(ls "$results_dir" | grep -c '\.skip$' || true)
  fails=$(ls "$results_dir" | grep -c '\.fail$' || true)
  total=$((n_ok + fails))
  rm -rf "$results_dir"
fi

rm -f "$effective_entries"
summary="[unit-test-runner] $((total-fails))/$total allowlisted unit-test files passed"
if [ "$skips" -ne 0 ]; then
  summary="$summary ($skips skipped: wasmtime not installed)"
fi
echo "$summary"
if [ "$fails" -ne 0 ]; then
  echo "[unit-test-runner] FAIL: $fails allowlisted unit-test file(s) regressed" >&2
  exit 1
fi
echo "[unit-test-runner] ok"
