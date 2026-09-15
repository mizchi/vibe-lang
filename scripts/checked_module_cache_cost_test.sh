#!/usr/bin/env bash
# Red test for the sample-acceptance rules in
# scripts/checked_module_cache_cost.mjs (#2836 §2).
#
# The measurement's protocol -- isolated cache per lane, cold then warm inside
# it, medians over rounds -- was correct and UNCHECKED: nothing verified that
# the run called "warm" had consumed anything, so if either mode stopped
# publishing or consuming, the report would compare cold against cold and
# attribute the difference to reuse that never happened. That is the #2825 §3
# failure (a cache that replayed nothing while the numbers looked healthy),
# reproduced inside the tool built to catch it.
#
# The rules that now reject such a sample are only worth something if they can
# fire, so each case below breaks the protocol in one specific way and requires
# the measurement to refuse by name. The mutation is applied to a COPY dropped
# next to the original -- it has to sit in scripts/ for the relative imports and
# the repo-root derivation to resolve -- rather than to the file itself, so a
# killed run cannot leave a corrupted script behind.
#
# Only the `closure` corpus is measured (--cases): four ~5s compiles per case
# instead of four ~20s ones. The rules are per-sample, so the small corpus
# exercises every one of them.
#
# Portability (#2252): nothing inherited, no non-POSIX tools.
set -euo pipefail
cd "$(dirname "$0")/.."
unset VIBE_CHECKED_MODULE_CACHE VIBE_CODEGEN_BODY_CACHE VIBE_BUILD_CACHE_DIR

. scripts/resolve_stage2.sh
stage2="$(resolve_stage2_strict checked-module-cost-test "${VIBE_STAGE2_WASM:-}")" || exit 1

work="$(mktemp -d "${TMPDIR:-/tmp}/vibe_checked_module_cost_test.XXXXXX")"
mutant="scripts/checked_module_cache_cost.redtest.mjs"
trap 'rm -rf "$work" "$mutant"' EXIT
failures=0

# $1 case name, $2 expected substring of the refusal, $3 python literal to
# replace, $4 its replacement.
expect_red() {
  local name="$1" expected="$2" from="$3" to="$4"
  rm -f "$mutant"
  # A mutation that matched nothing would leave the measurement intact and the
  # case would "pass" having proved nothing (#2248).
  FROM="$from" TO="$to" MUTANT="$mutant" python3 - <<'PY'
import os, pathlib
text = pathlib.Path("scripts/checked_module_cache_cost.mjs").read_text()
frm, to = os.environ["FROM"], os.environ["TO"]
count = text.count(frm)
if count != 1:
    raise SystemExit(f"mutation matched {count} times, expected exactly 1: {frm!r}")
pathlib.Path(os.environ["MUTANT"]).write_text(text.replace(frm, to, 1))
PY
  local log="$work/$name.log"
  if node "$mutant" "$stage2" --rounds 1 --cases closure --out "$work/$name" >"$log" 2>&1; then
    echo "[checked-module-cost-test] FAIL: $name was accepted; the rule cannot fire" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -qF "$expected" "$log"; then
    echo "[checked-module-cost-test] FAIL: $name failed for the wrong reason (wanted \"$expected\")" >&2
    tail -n 12 "$log" >&2
    failures=$((failures + 1))
    return
  fi
  echo "[checked-module-cost-test] red ok: $name"
}

# 1. The defect itself: a cache directory per TEMPERATURE, so the run labelled
#    warm starts empty. Every timing still lands, the outputs still match, and
#    the ratio is then a measurement of the machine.
expect_red cold-vs-cold "the warm run reused nothing" \
  'VIBE_BUILD_CACHE_DIR: cache,' \
  'VIBE_BUILD_CACHE_DIR: (mkdirSync(`${cache}-${temperature}`, { recursive: true }), `${cache}-${temperature}`),'

# 2. The other direction: a run labelled cold that starts from a populated
#    directory. Asymmetric warming is what made a +3.5% regression read as a
#    "-31%/-42% win" in #2393, and it does not announce itself in the timings.
expect_red warm-labelled-cold "it is not a cold sample" \
  'for (const temperature of ["cold", "warm"]) {
        const name =' \
  'for (const temperature of ["cold", "warm", "cold"]) {
        const name ='

# 3. The lane stops being the lane. If `on` were to run with the cache off, the
#    report would still print two lanes and a ratio between them -- of one mode
#    against itself. The telemetry schema says which mode answered, so this is
#    refused a step before the missing artifacts would be noticed.
expect_red lane-is-not-the-lane "expected 5 on the on lane" \
  'VIBE_CHECKED_MODULE_CACHE: lane,' \
  'VIBE_CHECKED_MODULE_CACHE: "off",'

# The green control. Without it a measurement that always refused would pass
# every case above while measuring nothing at all.
rm -f "$mutant"
if ! node scripts/checked_module_cache_cost.mjs "$stage2" --rounds 1 --cases closure \
     --out "$work/green" >"$work/green.log" 2>&1; then
  echo "[checked-module-cost-test] FAIL: an unmutated run was refused" >&2
  tail -n 12 "$work/green.log" >&2
  failures=$((failures + 1))
else
  echo "[checked-module-cost-test] green ok: unmutated run"
fi

if [ "$failures" -ne 0 ]; then
  echo "[checked-module-cost-test] FAIL: $failures case(s)" >&2
  exit 1
fi
echo "[checked-module-cost-test] ok"
