#!/usr/bin/env bash
# Self-test for scripts/reserved_pages_kpi.{sh,mjs} (#3647): the gate must be
# able to FAIL, and every way it can is exercised here against the COMMITTED
# baseline and a mutated copy of it.
#
# The compile is replaced by a fake runner (selfcompile_kpi.sh's
# VIBE_KPI_RUNNER_SCRIPT hook) that reports a page count per probe, so the
# test runs in seconds and needs no stage2. Everything after the runner -- the
# real selfcompile_kpi.sh, the parse, the closure walk over real files, the
# threshold and the exit code -- is the code under test.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Nothing inherited may steer the gate (#2252).
unset VIBE_PAGES_KPI_BASELINE VIBE_PAGES_KPI_VIBE VIBE_KPI_RUNNER_SCRIPT VIBE_STAGE2_WASM \
  VIBE_KPI_WORK_DIR VIBE_KPI_MAX_HEAP_BYTES VIBE_KPI_MAX_WALL_MS FAKE_PAGES_TABLE FAKE_OMIT_PAGES \
  FAKE_TRIAL_COUNTER FAKE_DRIFT_PROBE

BASELINE="bench/perf/reserved_pages_baseline.tsv"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reserved_pages_kpi_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

# --- fakes -------------------------------------------------------------------
# Pages per probe come from FAKE_PAGES_TABLE (`probe pages` lines). With
# FAKE_DRIFT_PROBE set, the second trial of that probe reports 50% more pages.
cat > "$WORK/runner.sh" <<'EOF'
#!/usr/bin/env bash
input="$4"; out="$5"
pages="$(awk -v p="$input" '$1 == p { print $2 }' "$FAKE_PAGES_TABLE")"
[ -n "$pages" ] || { echo "fake runner: no pages for $input" >&2; exit 3; }
if [ -n "${FAKE_DRIFT_PROBE:-}" ] && [ "$input" = "$FAKE_DRIFT_PROBE" ]; then
  n=$(( $(cat "$FAKE_TRIAL_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_TRIAL_COUNTER"
  [ "$n" -eq 2 ] && pages=$(( pages * 3 / 2 ))
fi
printf '\0asm\1\0\0\0' > "$out"
if [ -n "${FAKE_OMIT_PAGES:-}" ]; then
  echo "[wasm-memory] cli_main bytes=$((pages * 65536)) heap_ptr=4096 rss=1" >&2
else
  echo "[wasm-memory] cli_main pages=$pages bytes=$((pages * 65536)) heap_ptr=4096 rss=1" >&2
fi
EOF
# `vibe deps` stand-in: the closure is the probe alone, unless told otherwise.
cat > "$WORK/vibe.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = deps ] || exit 9
[ -n "${FAKE_DEPS_EXTRA:-}" ] && echo "$FAKE_DEPS_EXTRA"
exit 0
EOF
printf 'not a real compiler' > "$WORK/stage2.wasm"

# The committed baseline's own rows, as the fake runner's answers.
grep -E '^case ' "$BASELINE" | awk '{ print $2, $3 }' > "$WORK/at_baseline.txt"
[ -s "$WORK/at_baseline.txt" ] || { echo "no case rows in $BASELINE" >&2; exit 1; }
first_probe="$(awk 'NR == 1 { print $1 }' "$WORK/at_baseline.txt")"
first_pages="$(awk 'NR == 1 { print $2 }' "$WORK/at_baseline.txt")"
tolerance="$(awk '$1 == "tolerance_percent" { print $2 }' "$BASELINE")"
gate=$(( first_pages * (100 + tolerance) / 100 ))

kpi() { # <pages-table> <baseline> [args...]; sets out / rc
  local table="$1" base="$2"
  shift 2
  set +e
  out="$(FAKE_PAGES_TABLE="$table" VIBE_PAGES_KPI_BASELINE="$base" \
    VIBE_KPI_RUNNER_SCRIPT="$WORK/runner.sh" VIBE_PAGES_KPI_VIBE="$WORK/vibe.sh" \
    node scripts/reserved_pages_kpi.mjs "$WORK/stage2.wasm" --trials 3 "$@" 2>&1)"
  rc=$?
  set -e
}

with_pages() { # <probe> <pages> -> a table equal to the baseline but for one probe
  awk -v p="$1" -v n="$2" '$1 == p { $2 = n } { print }' "$WORK/at_baseline.txt" > "$WORK/table.txt"
  echo "$WORK/table.txt"
}

echo "[reserved-pages-kpi-test] baseline=$BASELINE probe=$first_probe pages=$first_pages gate=$gate"

# 1. Every probe at its committed baseline passes.
kpi "$WORK/at_baseline.txt" "$BASELINE"
if [ "$rc" -eq 0 ] && grep -q "probe=$first_probe .*status=ok" <<<"$out"; then
  ok "every probe at the committed baseline passes"
else
  bad "baseline run should pass (rc=$rc): $out"
fi

# 2. Exactly at the threshold passes; one page over fails.
kpi "$(with_pages "$first_probe" "$gate")" "$BASELINE"
[ "$rc" -eq 0 ] && ok "a probe at the threshold ($gate pages) passes" || bad "threshold run should pass (rc=$rc): $out"
kpi "$(with_pages "$first_probe" $((gate + 1)))" "$BASELINE"
if [ "$rc" -eq 1 ] && grep -q "GATE FAIL probe=$first_probe" <<<"$out"; then
  ok "one page over the threshold fails"
else
  bad "over-threshold run should fail with GATE FAIL (rc=$rc): $out"
fi

# 3. --report-only reports the same verdict and does not fail.
kpi "$(with_pages "$first_probe" $((gate + 1)))" "$BASELINE" --report-only
if [ "$rc" -eq 0 ] && grep -q "status=over-threshold" <<<"$out"; then
  ok "--report-only prints over-threshold and exits 0"
else
  bad "--report-only (rc=$rc): $out"
fi

# 4. A mutated COMMITTED baseline: lowering one row by 20% must turn the
#    unchanged measurement into a failure. Verify the mutation hit first.
lowered=$(( first_pages * 80 / 100 ))
awk -v p="$first_probe" -v n="$lowered" '$1 == "case" && $2 == p { $3 = n } { print }' "$BASELINE" > "$WORK/mutated.tsv"
if cmp -s "$BASELINE" "$WORK/mutated.tsv"; then
  bad "the baseline mutation did not change the file"
else
  kpi "$WORK/at_baseline.txt" "$WORK/mutated.tsv"
  [ "$rc" -eq 1 ] && grep -q "GATE FAIL probe=$first_probe" <<<"$out" \
    && ok "a baseline lowered by 20% fails the unchanged measurement" \
    || bad "lowered baseline should fail (rc=$rc): $out"
fi

# 5. A missing page count is an instrumentation failure, never zero.
set +e
out="$(FAKE_OMIT_PAGES=1 FAKE_PAGES_TABLE="$WORK/at_baseline.txt" VIBE_PAGES_KPI_BASELINE="$BASELINE" \
  VIBE_KPI_RUNNER_SCRIPT="$WORK/runner.sh" VIBE_PAGES_KPI_VIBE="$WORK/vibe.sh" \
  node scripts/reserved_pages_kpi.mjs "$WORK/stage2.wasm" --trials 1 --report-only 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "instrumentation failure: mem_pages" <<<"$out" && ! grep -q "status=ok" <<<"$out"; then
  ok "a missing page count fails as instrumentation, even with --report-only"
else
  bad "missing pages should fail (rc=$rc): $out"
fi

# 6. The gate reads the WORST trial: one drifting trial of three fails.
set +e
out="$(FAKE_DRIFT_PROBE="$first_probe" FAKE_TRIAL_COUNTER="$WORK/counter" FAKE_PAGES_TABLE="$WORK/at_baseline.txt" \
  VIBE_PAGES_KPI_BASELINE="$BASELINE" VIBE_KPI_RUNNER_SCRIPT="$WORK/runner.sh" VIBE_PAGES_KPI_VIBE="$WORK/vibe.sh" \
  node scripts/reserved_pages_kpi.mjs "$WORK/stage2.wasm" --trials 3 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "probe=$first_probe .*pages_spread=[1-9]" <<<"$out"; then
  ok "one trial of three over the threshold fails, and the spread is reported"
else
  bad "a drifting trial should fail (rc=$rc): $out"
fi

# 7. A closure member that does not exist is refused, not skipped.
set +e
out="$(FAKE_DEPS_EXTRA="lib/@vibe/no_such_package/missing.vibe" FAKE_PAGES_TABLE="$WORK/at_baseline.txt" \
  VIBE_PAGES_KPI_BASELINE="$BASELINE" VIBE_KPI_RUNNER_SCRIPT="$WORK/runner.sh" VIBE_PAGES_KPI_VIBE="$WORK/vibe.sh" \
  node scripts/reserved_pages_kpi.mjs "$WORK/stage2.wasm" --trials 1 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] && grep -q "which does not exist" <<<"$out" \
  && ok "a closure member that does not exist fails" || bad "missing closure member (rc=$rc): $out"

# 8. A baseline row naming a probe that is not in the tree fails.
sed "s|^case $first_probe |case lib/@vibe/no_such_package/gone_test.vibe |" "$BASELINE" > "$WORK/renamed.tsv"
if cmp -s "$BASELINE" "$WORK/renamed.tsv"; then
  bad "the probe rename did not change the file"
else
  kpi "$WORK/at_baseline.txt" "$WORK/renamed.tsv" --report-only
  [ "$rc" -eq 1 ] && grep -q "probe not found" <<<"$out" \
    && ok "a baseline probe missing from the tree fails" || bad "missing probe (rc=$rc): $out"
fi

# 9. A baseline without its threshold, or with an unknown directive, is refused.
grep -v '^tolerance_percent' "$BASELINE" > "$WORK/no_tol.tsv"
kpi "$WORK/at_baseline.txt" "$WORK/no_tol.tsv"
[ "$rc" -eq 1 ] && grep -q "no tolerance_percent" <<<"$out" \
  && ok "a baseline with no tolerance is refused" || bad "no tolerance (rc=$rc): $out"
{ cat "$BASELINE"; echo "case_pages lib/x 1 1"; } > "$WORK/junk.tsv"
kpi "$WORK/at_baseline.txt" "$WORK/junk.tsv"
[ "$rc" -eq 1 ] && grep -q "unrecognised directive" <<<"$out" \
  && ok "an unknown baseline directive is refused" || bad "unknown directive (rc=$rc): $out"

# 10. The wrapper refuses to measure the committed seed.
set +e
out="$(VIBE_STAGE2_WASM=bootstrap/seed/compiler.wasm bash scripts/reserved_pages_kpi.sh 2>&1)"
rc=$?
set -e
if [ ! -f bootstrap/seed/compiler.wasm ]; then
  # resolve_stage2_strict refuses an override that does not exist, also exit 1.
  [ "$rc" -eq 1 ] && ok "the wrapper refuses a missing seed override" || bad "seed override (rc=$rc): $out"
else
  [ "$rc" -eq 1 ] && grep -q "the seed cannot measure" <<<"$out" \
    && ok "the wrapper refuses to measure the committed seed" || bad "seed override (rc=$rc): $out"
fi

echo "[reserved-pages-kpi-test] passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
