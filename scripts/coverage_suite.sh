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
#     entry_weighted: {function: {hit, total, rate}, branch: {hit, total, rate}},
#     entries_total/entries_passed/case_rate,
#     top_branch_gaps: [{entry_path, branch_hit, branch_total, branch_miss}] }
# `function_union` is the primary source-function metric. Entry-weighted
# function/branch values retain the existing gate semantics; branch IDs are not
# available in the per-entry JSON, so branch union cannot be computed exactly.
#
# Thresholds (percent, env-overridable; shard defaults live in
# scripts/pkfire/gates_shard.sh — raise them as coverage improves,
# lowering needs a rationale in the PR):
#   VIBE_SUITE_MIN_POINT_RATE  — minimum FUNCTION coverage (fn hit/total)
#   VIBE_SUITE_MIN_LINE_RATE   — minimum CASE PASS rate (entries green)
#   VIBE_SUITE_MIN_BRANCH_RATE — minimum BRANCH coverage (branch hit/total)
#   VIBE_SUITE_MIN_FN_HIT      — minimum ABSOLUTE covered functions
#   VIBE_SUITE_MIN_BRANCH_HIT  — minimum ABSOLUTE covered branches
#
# The ABSOLUTE minimums are the primary ratchet: adding a test entry can only
# raise them, while the RATE floors would punish it (a new entry grows the
# denominator by its whole import closure). Rates are kept as loose floors.
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
# #1090 threads/@vibex/concurrent + structural Send, #1091 LSP server
# completion/signatureHelp/workspaceSymbol, #1093/#1094 follow-ups):
# functions 45,324/322,132 (14.07%), branches 122,370/1,928,107 (6.35%) on
# main -- absolute hit counts at all-time highs (fn 34,710 -> 45,324,
# branch ~99k -> 122,370) while the rates diluted below the old 20%/7%
# floors, failing every main push since 2026-07-23. Same dilution shape as
# the #801/#847 notes above, not a coverage regression. Rate mins lowered
# just under current; the ABSOLUTE mins (the real ratchet) are RAISED to
# just under current instead (12,000 -> 42,000 fn, 29,000 -> 113,000
# branch), which protects strictly more coverage than the old floors did.
MIN_POINT="${VIBE_SUITE_MIN_POINT_RATE:-13}"
MIN_LINE="${VIBE_SUITE_MIN_LINE_RATE:-97}"
MIN_BRANCH="${VIBE_SUITE_MIN_BRANCH_RATE:-6}"
MIN_FN_HIT="${VIBE_SUITE_MIN_FN_HIT:-42000}"
MIN_BRANCH_HIT="${VIBE_SUITE_MIN_BRANCH_HIT:-113000}"

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
  revision="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
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

python3 scripts/coverage_suite_report.py "$run_log" "$COV_DIR" "$REPORT" "$MIN_POINT" "$MIN_LINE" "$MIN_BRANCH" "$MIN_FN_HIT" "$MIN_BRANCH_HIT"
