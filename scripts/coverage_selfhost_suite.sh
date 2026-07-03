#!/usr/bin/env bash
# #535: selfhost mainline coverage gate.
#
# Runs the selfhost unit-test allowlist (scripts/selfhost_unit_test_allowlist.txt,
# plus VIBE_SELFHOST_SUITE_EXTRA_ENTRIES=a.vibe,b.vibe) under
# `vibe test --coverage` (function/branch hit instrumentation, linear backend),
# aggregates per-entry coverage, writes the suite report consumed by
# scripts/coverage_selfhost_suite_next_branches.mjs, and enforces ratcheting
# minimum rates.
#
# Report: _build/coverage/selfhost-suite/selfhost_suite.report.json
#   { cases: [{entry_path, ok, fn_hit, fn_total, branch_hit, branch_total}],
#     fn_hit/fn_total/fn_rate, branch_hit/branch_total/branch_rate,
#     entries_total/entries_passed/case_rate,
#     top_branch_gaps: [{entry_path, branch_hit, branch_total, branch_miss}] }
#
# Thresholds (percent, env-overridable; shard defaults live in
# scripts/pkfire/selfhost_gates_shard.sh — raise them as coverage improves,
# lowering needs a rationale in the PR):
#   VIBE_SELFHOST_SUITE_MIN_POINT_RATE  — minimum FUNCTION coverage (fn hit/total)
#   VIBE_SELFHOST_SUITE_MIN_LINE_RATE   — minimum CASE PASS rate (entries green)
#   VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE — minimum BRANCH coverage (branch hit/total)
#
# Baseline (2026-07-03, 89 allowlist entries, stage2 of the #716 branch):
#   functions 1980/5196 (38.11%), branches 2832/29591 (9.57%), cases 88/89
#   (the known TCP-sandbox failure). Defaults sit just below those actuals.
#   The branch denominator counts every if/match branch of the transitively
#   imported modules, hence the low absolute rate — the ratchet direction is
#   what the gate protects.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIN_POINT="${VIBE_SELFHOST_SUITE_MIN_POINT_RATE:-37}"
MIN_LINE="${VIBE_SELFHOST_SUITE_MIN_LINE_RATE:-97}"
MIN_BRANCH="${VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE:-9}"

ALLOWLIST="scripts/selfhost_unit_test_allowlist.txt"
OUT_DIR="_build/coverage/selfhost-suite"
REPORT="$OUT_DIR/selfhost_suite.report.json"
COV_DIR="_build/vibe_test/coverage"

# Compiling CLI: explicit override > the unit-runner override > the newest
# generation stage2 > the committed seed.
cli="${VIBE_SELFHOST_SUITE_CLI_WASM:-${VIBE_SELFHOST_STAGE2_WASM:-}}"
if [ -z "$cli" ]; then
  gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
  if [ -n "$gen" ] && [ -f "${gen}stage2.wasm" ]; then
    cli="${gen}stage2.wasm"
  else
    cli="bootstrap/selfhost/seed/selfhost_compiler.wasm"
  fi
fi
if [ ! -f "$cli" ]; then
  echo "[coverage-suite] compiling CLI not found: $cli" >&2
  exit 1
fi

entries=()
while IFS= read -r line; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  entries+=("$line")
done < "$ALLOWLIST"
if [ -n "${VIBE_SELFHOST_SUITE_EXTRA_ENTRIES:-}" ]; then
  IFS=',' read -r -a extra <<< "$VIBE_SELFHOST_SUITE_EXTRA_ENTRIES"
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
VIBE_TEST_CLI_WASM="$ROOT/$cli" bash scripts/vibe_test.sh --coverage "${entries[@]}" \
  | tee "$run_log" || true

python3 - "$run_log" "$COV_DIR" "$REPORT" "$MIN_POINT" "$MIN_LINE" "$MIN_BRANCH" <<'PY'
import json, os, re, sys

run_log, cov_dir, report_path, min_point, min_line, min_branch = sys.argv[1:7]
min_point, min_line, min_branch = float(min_point), float(min_line), float(min_branch)

cases = []
for line in open(run_log, encoding="utf-8"):
    m = re.match(r"^(ok|FAIL)\s+(\S+\.vibe)", line.strip())
    if not m:
        continue
    ok = m.group(1) == "ok"
    entry = m.group(2)
    flat = entry.replace("/", "_")
    flat = re.sub(r"\.vibe$", "", flat)
    cov = os.path.join(cov_dir, flat + ".json")
    fn_hit = fn_total = br_hit = br_total = 0
    if ok and os.path.isfile(cov):
        r = json.load(open(cov, encoding="utf-8"))
        fn_hit, fn_total = r.get("hit", 0), r.get("total", 0)
        b = r.get("branch") or {}
        br_hit, br_total = b.get("hit", 0), b.get("total", 0)
    cases.append({
        "entry_path": entry, "ok": ok,
        "fn_hit": fn_hit, "fn_total": fn_total,
        "branch_hit": br_hit, "branch_total": br_total,
    })

entries_total = len(cases)
entries_passed = sum(1 for c in cases if c["ok"])
fn_hit = sum(c["fn_hit"] for c in cases)
fn_total = sum(c["fn_total"] for c in cases)
br_hit = sum(c["branch_hit"] for c in cases)
br_total = sum(c["branch_total"] for c in cases)
fn_rate = round(fn_hit / fn_total * 100, 2) if fn_total else 0.0
br_rate = round(br_hit / br_total * 100, 2) if br_total else 0.0
case_rate = round(entries_passed / entries_total * 100, 2) if entries_total else 0.0

gaps = [
    {
        "entry_path": c["entry_path"],
        "branch_hit": c["branch_hit"],
        "branch_total": c["branch_total"],
        "branch_miss": c["branch_total"] - c["branch_hit"],
    }
    for c in cases
    if c["ok"] and c["branch_total"] > 0 and c["branch_total"] > c["branch_hit"]
]
gaps.sort(key=lambda g: -g["branch_miss"])

report = {
    "suite": "selfhost-unit-allowlist",
    "entries_total": entries_total,
    "entries_passed": entries_passed,
    "case_rate": case_rate,
    "fn_hit": fn_hit, "fn_total": fn_total, "fn_rate": fn_rate,
    "branch_hit": br_hit, "branch_total": br_total, "branch_rate": br_rate,
    "cases": cases,
    "top_branch_gaps": gaps[:10],
    "top_non_aggregate_branch_gaps": [],
}
os.makedirs(os.path.dirname(report_path), exist_ok=True)
json.dump(report, open(report_path, "w", encoding="utf-8"), indent=2)

print(f"[coverage-suite] cases {entries_passed}/{entries_total} ({case_rate}%)")
print(f"[coverage-suite] functions {fn_hit}/{fn_total} ({fn_rate}%)")
print(f"[coverage-suite] branches {br_hit}/{br_total} ({br_rate}%)")
print(f"[coverage-suite] report: {report_path}")

failures = []
if fn_rate < min_point:
    failures.append(f"function coverage {fn_rate}% < min {min_point}% (POINT)")
if case_rate < min_line:
    failures.append(f"case pass rate {case_rate}% < min {min_line}% (LINE)")
if br_rate < min_branch:
    failures.append(f"branch coverage {br_rate}% < min {min_branch}% (BRANCH)")
if failures:
    for f in failures:
        print(f"[coverage-suite] GATE FAIL: {f}")
    sys.exit(1)
print("[coverage-suite] gate ok")
PY
