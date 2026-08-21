#!/usr/bin/env bash
# #535: selfhost mainline coverage gate.
#
# Runs the selfhost unit-test battery (scripts/unit_test_runner.sh --list --
# every discovered *_test.vibe minus that script's small EXCLUDE_PATTERNS
# list; #1231 removed the hand-maintained allowlist file this used to read
# directly, plus VIBE_SUITE_EXTRA_ENTRIES=a.vibe,b.vibe) under
# `vibe test --coverage` (function/branch hit instrumentation, linear backend),
# aggregates per-entry coverage, writes the suite report consumed by
# scripts/coverage_suite_next_branches.mjs, and enforces ratcheting
# minimum rates.
#
# Report: _build/coverage/selfhost-suite/selfhost_suite.report.json
#   { cases: [{entry_path, ok, fn_hit, fn_total, branch_hit, branch_total}],
#     function_union: {hit, total, rate},
#     branch_union: {hit, total, rate, exact},
#     entry_weighted: {function: {hit, total, rate}, branch: {hit, total, rate}},
#     entries_total/entries_passed/case_rate,
#     top_branch_gaps: [{entry_path, branch_hit, branch_total, branch_miss}],
#     top_branch_union_gaps: [{fn, branch_hit, branch_total, branch_miss}] }
# `function_union` / `branch_union` (#1556) are the primary source metrics:
# each source function / branch counted once no matter how many entries link
# it. The entry-weighted values retain the existing gate semantics and are
# NOT source coverage -- their denominator is summed per entry, so the same
# imported module is counted once per test file that pulls it in.
#
# WHAT THIS MEASURES: the compiled TEST PROGRAM's own execution. Compiler
# passes that ran while COMPILING a test are inside the (uninstrumented)
# stage2, so they contribute nothing -- a compiler pass appears here only when
# some test calls it IN-PROCESS. Measured both directions: grep_test.vibe
# calls grep_scan_source directly and lights 264/587 of grep.vibe, while
# import_private_ctor_collision_test.vibe (which exercises private-ctor
# namespacing at COMPILE time) yields a program with 8 branches total and no
# import_alias_rewrite function in it at all. So a 0% module here means "no
# test calls it in-process", NOT "untested" -- see docs/coverage.md before
# treating top_branch_union_gaps as a to-do list.
#
# Thresholds (percent, env-overridable; this file is the ONE place they are
# defined):
#   VIBE_SUITE_MIN_POINT_RATE        — opt-in entry-weighted FUNCTION floor
#   VIBE_SUITE_MIN_LINE_RATE         — minimum CASE PASS rate (entries green)
#   VIBE_SUITE_MIN_BRANCH_RATE       — opt-in entry-weighted BRANCH floor
#   VIBE_SUITE_MIN_FN_HIT            — minimum ABSOLUTE covered functions
#   VIBE_SUITE_MIN_BRANCH_HIT        — minimum ABSOLUTE covered branches
#   VIBE_SUITE_MIN_FUNCTION_UNION_HIT — minimum UNION covered functions
#   VIBE_SUITE_MIN_FUNCTION_UNION_RATE — opt-in UNION function rate
#   VIBE_SUITE_MIN_BRANCH_UNION_HIT  — minimum UNION covered branches
#   VIBE_SUITE_MIN_BRANCH_UNION_RATE — minimum UNION branch rate
#
# Among the ENTRY-WEIGHTED metrics only the ABSOLUTE minimums are ratchets:
# adding a test entry can only raise them, while rate floors punish it (a new
# entry grows the denominator by its whole import closure). The rates remain
# in the report and can be gated explicitly through the env overrides, but
# their defaults are zero. Union ABSOLUTE hits are monotonic across test-entry
# expansion; rates are only default gates where a separate source-coverage KPI
# explicitly requires one (the #1556 branch target).
#
# Baseline (2026-07-03, 93 allowlist entries, full-visibility #716 stage2):
#   functions 2263/6491 (34.86%), branches 3814/41967 (9.09%), cases 92/93
#   (the known TCP-sandbox failure). Defaults sit just below those actuals;
#   the #716 full-rename grew the fn denominator (previously-conflated
#   same-name exports now count as distinct functions) while ABSOLUTE hits
#   rose 2167 -> 2263 / 3473 -> 3814 — the ratchet metrics moved up.
#   The branch denominator counts every if/match branch of the transitively
#   imported modules, hence the low absolute rate — the ratchet direction is
#   what the gate protects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Rebaselined 2026-07-05: the allowlist doubled (110 -> 224 files), and every
# added test file contributes its WHOLE compiled module (prelude + imports) to
# the fn/branch denominators, diluting the RATES even though absolute covered
# counts rose ~5x (fn hit 2,4xx -> 12,476; branch hit 4,1xx -> 30,343). The
# ABSOLUTE mins below are the real anti-regression ratchet and are raised to
# just under current; the rate mins are recalibrated to the diluted baseline.
#
# Rebaselined again 2026-07-15 (#801): fixing a loader cache-corruption bug
# (lib/@vibe/compiler/loader/manifest_sources.vibe's ensure_grouped_source_bucket)
# let cache_probe_loader_manifest_groups_bench_test.vibe start compiling and
# running correctly instead of crashing -- previously its whole transitive
# denominator (and the crash-excluded 0 numerator) was left out of the suite
# entirely. Its own local hit ratio (~17%) is below the suite average, so
# correctly including it dips the aggregate POINT rate from 23% to ~22.9%
# even though absolute hit counts only went UP (this entry's functions are
# now genuinely exercised, not uncounted). MIN_POINT lowered just enough to
# accommodate; MIN_FN_HIT (the real anti-regression ratchet per the note
# above) is unaffected and still comfortably cleared.
#
# Rebaselined again 2026-07-15 (#847): mechanically rerouting ~44 direct leaf
# imports to go through their directory's index.vibe facade (parser.vibe's
# syntax/ imports alone fan out to ~20 test files, plus prelude/json/process
# facade widening) grows the whole-program-merge denominator further --
# functions 34671/153688 (22.56%) on main -> 34710/168826 (20.56%) with this
# change. Hit count went UP (+39, not down), total reachable functions grew
# ~9.8% (+15,138) because widened facades pull more already-compiled code
# into every test's merged program. Same dilution shape as the #801 note
# above, not a coverage regression. MIN_POINT lowered just enough to
# accommodate with a small margin; MIN_FN_HIT is unaffected and still
# cleared by ~3x (34,710 vs 12,000).
#
# Rebaselined again 2026-07-25: the run-up to 0.4.0 roughly doubled the
# corpus again (224 -> 467 allowlisted files) and landed several large
# subsystems in the compiler tree that every compiler test's merged program
# now pulls into its denominator (#1086 checked-Error row + entry boundary,
# #1090 threads/@vibe/concurrent + structural Send, #1091 LSP server
# completion/signatureHelp/workspaceSymbol, #1093/#1094 follow-ups):
# functions 45,324/322,132 (14.07%), branches 122,370/1,928,107 (6.35%) on
# main -- absolute hit counts at all-time highs (fn 34,710 -> 45,324,
# branch ~99k -> 122,370) while the rates diluted below the old 20%/7%
# floors, failing every main push since 2026-07-23. Same dilution shape as
# the #801/#847 notes above, not a coverage regression. Rate mins lowered
# just under current; the ABSOLUTE mins (the real ratchet) are RAISED to
# just under current instead (12,000 -> 42,000 fn, 29,000 -> 113,000
# branch), which protects strictly more coverage than the old floors did.
#
# Rebased 2026-08-21: with 1,008 entries, the entry-weighted rates diluted to
# 12.35% / 5.50% while absolute hits reached 111,304 / 282,489 and source
# union stayed at 88.42% / 58.73%. Main had been red before and after #2156
# despite every one of the 1,008 entries passing. Repeatedly lowering a rate
# whose denominator grows with each entry is not a ratchet, so the default
# rate floors are retired. Absolute-hit and union ratchets below remain active.
MIN_POINT="${VIBE_SUITE_MIN_POINT_RATE:-0}"
MIN_LINE="${VIBE_SUITE_MIN_LINE_RATE:-97}"
MIN_BRANCH="${VIBE_SUITE_MIN_BRANCH_RATE:-0}"
MIN_FN_HIT="${VIBE_SUITE_MIN_FN_HIT:-42000}"
MIN_BRANCH_HIT="${VIBE_SUITE_MIN_BRANCH_HIT:-113000}"
# Union floors count each source function/branch once no matter how many
# entries link it. Their absolute hits are safe ratchets. Their source universe
# can still expand when a test first imports a module, so only the #1556 branch
# coverage KPI has a default rate floor; function-union rate remains opt-in.
#
# Baseline (2026-08-13, 575 entries, all green, at 85f2ace): branch union
# 25,131/45,638 (55.07%), function union 12,820/14,907 (86.00%). Note how far
# these sit from the entry-weighted numbers on the SAME run (branches 6.23%,
# functions 14.04%) -- that gap is entirely denominator dilution, not coverage.
# Measured at 6df97b0 too (55.08%), so the metric is stable across bases.
# Floors are set just under the actuals, same convention as the ratchets above.
#
# Raised 2026-08-13 (#1556, derived-`==` tests): 582 entries, branch union
# 26,442/45,986 (57.50%), function union 12,950/14,995 (86.36%). The seven
# `*_eq_test.vibe` files call the DERIVED `T::equals` that `desugar_derives`
# emits for every enum -- 1,710 branches across 96 types that no test had ever
# called. Floors moved 24,500 -> 26,000 and 54% -> 57%.
#
# Both figures went UP slightly when union_key started source-qualifying the
# entry-local synthesized names (Codex review on #1668): the un-merged
# `__test_<name>` collisions and the 575 separate `_start` wrappers are now
# counted individually instead of collapsing onto one key. The branch RATE is
# unchanged (55.07%) -- numerator and denominator grew together, which is what
# de-merging distinct functions should do.
#
# #2175 review: retiring the diluted function-rate floor without a function
# union ratchet would leave only MIN_FN_HIT=42,000 against 111,304 weighted
# hits. Current source-function union is 16,040/18,147 (88.39%) locally and
# 16,046/18,147 (88.42%) in CI. Protect the executed source-function count;
# do not gate its rate because a newly imported module expands the denominator
# without making any previously covered function uncovered (#2176 review).
MIN_FUNCTION_UNION_HIT="${VIBE_SUITE_MIN_FUNCTION_UNION_HIT:-15800}"
MIN_FUNCTION_UNION="${VIBE_SUITE_MIN_FUNCTION_UNION_RATE:-0}"
MIN_BRANCH_UNION_HIT="${VIBE_SUITE_MIN_BRANCH_UNION_HIT:-26000}"
MIN_BRANCH_UNION="${VIBE_SUITE_MIN_BRANCH_UNION_RATE:-57}"

ALLOWLIST="$(mktemp -t vibe-coverage-entries-XXXXXX)"
trap 'rm -f "$ALLOWLIST"' EXIT
bash scripts/unit_test_runner.sh --list > "$ALLOWLIST"
OUT_DIR="_build/coverage/selfhost-suite"
REPORT="$OUT_DIR/selfhost_suite.report.json"
COV_DIR="_build/vibe_test/coverage"

# Compiling CLI: explicit override > the generation built for this checkout.
# Do not select the newest directory by mtime: a worktree can retain a stage2
# from another revision, yielding stale coverage failures or false greens.
cli="${VIBE_SUITE_CLI_WASM:-${VIBE_STAGE2_WASM:-}}"
if [ -z "$cli" ]; then
  # Must match how scripts/generations.sh NAMES the directory, which uses a
  # bare `--short` (core.abbrev, 7 by default). Asking for `--short=8` here
  # made the glob miss every locally-built generation, so the lookup always
  # fell through to the "no stage2 built for this checkout" error even
  # straight after a successful build.
  revision="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "$revision" ]; then
    gen="$(ls -d "_build/selfhost/generations/"*"_${revision}/" 2>/dev/null | head -1 || true)"
  else
    gen=""
  fi
  if [ -n "$gen" ] && [ -f "${gen}stage2.wasm" ]; then
    cli="${gen}stage2.wasm"
  else
    echo "[coverage-suite] no stage2 built for this checkout; run 'pkf run generation' or set VIBE_SUITE_CLI_WASM" >&2
    exit 2
  fi
fi
if [ ! -f "$cli" ]; then
  echo "[coverage-suite] compiling CLI not found: $cli" >&2
  exit 1
fi

# #794: mirror the unit-test runner's echo-server start -- entries that drive
# real HTTP mention the local echo endpoint; start tests/http_echo_server.py
# for the run when any does (content-based, like the wasmtime gate below).
# #934: port derived per worktree and exported as VIBE_HTTP_ECHO_PORT, same
# as unit_test_runner.sh (the test reads the env var, default 18280).
http_echo_pid=""
http_echo_port="${VIBE_HTTP_ECHO_PORT:-$((18280 + $(printf '%s' "$ROOT" | cksum | cut -d' ' -f1) % 1000))}"
export VIBE_HTTP_ECHO_PORT="$http_echo_port"
start_http_echo_server_if_needed() {
  local need=0 f
  while IFS= read -r f; do
    case "$f" in ''|\#*) continue ;; esac
    if [ -f "$f" ] && grep -q "VIBE_HTTP_ECHO_PORT\|127.0.0.1:18280" "$f"; then need=1; break; fi
  done < "$ALLOWLIST"
  [ "$need" -eq 1 ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$ROOT/tests/http_echo_server.py" ] || return 0
  python3 "$ROOT/tests/http_echo_server.py" "$http_echo_port" >/dev/null 2>&1 &
  http_echo_pid=$!
  trap 'rm -f "$ALLOWLIST"; if [ -n "$http_echo_pid" ]; then kill "$http_echo_pid" 2>/dev/null || true; fi' EXIT
  sleep 1
  if ! kill -0 "$http_echo_pid" 2>/dev/null; then
    echo "[coverage-suite] WARN: http echo server failed to start on 127.0.0.1:$http_echo_port" >&2
    http_echo_pid=""
    return 0
  fi
  echo "[coverage-suite] started http echo server (pid $http_echo_pid, 127.0.0.1:$http_echo_port)"
}
start_http_echo_server_if_needed

# #769: mirror the unit-test runner's wasmtime gate -- tests that shell out to
# the standalone wasmtime CLI are covered in CI (ci.yml installs it) and
# skipped where it is absent.
have_wasmtime=0
command -v wasmtime >/dev/null 2>&1 && have_wasmtime=1
entries=()
while IFS= read -r line; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  if [ "$have_wasmtime" -eq 0 ] && [ -f "$line" ] && grep -q '"wasmtime run' "$line"; then
    echo "[coverage-suite] skip: $line (needs the wasmtime CLI; not installed)"
    continue
  fi
  entries+=("$line")
done < "$ALLOWLIST"
if [ -n "${VIBE_SUITE_EXTRA_ENTRIES:-}" ]; then
  IFS=',' read -r -a extra <<< "$VIBE_SUITE_EXTRA_ENTRIES"
  for e in "${extra[@]}"; do
    [ -n "$e" ] && entries+=("$e")
  done
fi
if [ "${#entries[@]}" -eq 0 ]; then
  echo "[coverage-suite] no entries" >&2
  exit 1
fi

echo "[coverage-suite] cli=$cli entries=${#entries[@]}"
rm -rf "$COV_DIR"
mkdir -p "$OUT_DIR"

run_log="$OUT_DIR/vibe_test.log"
# vibe_test.sh exits non-zero when any entry fails; the pass-rate threshold
# below decides gate success, so tolerate the exit code here.
# $cli may be absolute (CI passes VIBE_SUITE_CLI_WASM that way) — only
# rebase relative paths onto $ROOT. Blindly prefixing doubled the path
# ("$ROOT//home/runner/…") and instantly failed all 467 compiles on the
# first standalone coverage-suite run (2026-07-25).
case "$cli" in
  /*) cli_abs="$cli" ;;
  *) cli_abs="$ROOT/$cli" ;;
esac
VIBE_TEST_CLI_WASM="$cli_abs" bash scripts/vibe_test.sh --coverage "${entries[@]}" \
  | tee "$run_log" || true

python3 scripts/coverage_suite_report.py "$run_log" "$COV_DIR" "$REPORT" "$MIN_POINT" "$MIN_LINE" "$MIN_BRANCH" "$MIN_FN_HIT" "$MIN_BRANCH_HIT" "$MIN_BRANCH_UNION_HIT" "$MIN_BRANCH_UNION" "$MIN_FUNCTION_UNION_HIT" "$MIN_FUNCTION_UNION"
