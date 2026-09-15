#!/usr/bin/env bash
# Red test for the sample-acceptance rules in scripts/incremental_kpi.mjs
# (#2836 §2).
#
# The KPI's headline is a ratio of a warm rebuild to a cold one. Both names
# have to be earned, and until now neither was checked: the script reported the
# counters and divided the timings whatever the counters said, so a cache that
# stopped reusing would have produced a full table of ratios describing the
# machine. That is the failure #2825 §3 already had in the compiler,
# where a body cache replayed nothing for as long as it existed and every
# published number looked healthy.
#
# Each case below breaks one half of the protocol and requires the KPI to
# refuse by name. The mutation goes into a COPY dropped next to the original --
# it must sit in scripts/ for the relative imports and the repo-root derivation
# to resolve -- so a killed run cannot leave a corrupted script behind.
#
# Only the `small` corpus is measured (--corpora): the rules are per-corpus, so
# the smallest one exercises every one of them, at two ~1s compiles per case
# instead of six compiles including the selfhost closure.
#
# Portability (#2252): nothing inherited, no non-POSIX tools.
set -euo pipefail
cd "$(dirname "$0")/.."
unset VIBE_CHECKED_MODULE_CACHE VIBE_CODEGEN_BODY_CACHE VIBE_BUILD_CACHE_DIR

. scripts/resolve_stage2.sh
stage2="$(resolve_stage2_strict incremental-kpi-test "${VIBE_STAGE2_WASM:-}")" || exit 1

work="$(mktemp -d "${TMPDIR:-/tmp}/vibe_incremental_kpi_test.XXXXXX")"
mutant="scripts/incremental_kpi.redtest.mjs"
trap 'rm -rf "$work" "$mutant"' EXIT
failures=0

# $1 case name, $2 expected substring of the refusal, $3 literal to replace,
# $4 its replacement.
expect_red() {
  local name="$1" expected="$2" from="$3" to="$4"
  rm -f "$mutant"
  # A mutation that matched nothing would leave the KPI intact and the case
  # would "pass" having proved nothing (#2248).
  FROM="$from" TO="$to" MUTANT="$mutant" python3 - <<'PY'
import os, pathlib
text = pathlib.Path("scripts/incremental_kpi.mjs").read_text()
frm, to = os.environ["FROM"], os.environ["TO"]
count = text.count(frm)
if count != 1:
    raise SystemExit(f"mutation matched {count} times, expected exactly 1: {frm!r}")
pathlib.Path(os.environ["MUTANT"]).write_text(text.replace(frm, to, 1))
PY
  local log="$work/$name.log"
  if node "$mutant" "$stage2" "$work/$name.json" --corpora small >"$log" 2>&1; then
    echo "[incremental-kpi-test] FAIL: $name was accepted; the rule cannot fire" >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -qF "$expected" "$log"; then
    echo "[incremental-kpi-test] FAIL: $name failed for the wrong reason (wanted \"$expected\")" >&2
    tail -n 12 "$log" >&2
    failures=$((failures + 1))
    return
  fi
  echo "[incremental-kpi-test] red ok: $name"
}

# 1. A cache directory per RUN, so the rebuild called warm starts empty. The
#    wall and heap readings still land and the two builds still emit identical
#    wasm -- the equality check that was already here passes -- so nothing but
#    the counters can tell that no reuse happened.
expect_red cold-vs-cold "the warm rebuild reused nothing" \
  'VIBE_BUILD_CACHE_DIR: cache,' \
  'VIBE_BUILD_CACHE_DIR: (mkdirSync(`${cache}-${label}`, { recursive: true }), `${cache}-${label}`),'

# 2. The other direction: a warm-up before the run called cold, so the baseline
#    every ratio is divided by is itself a warm build. Asymmetric warming is
#    what turned a +3.5% regression into a "-31%/-42% win" in #2393, and it
#    does not announce itself in the timings.
expect_red warm-labelled-cold "it is not a cold baseline" \
  'const cold = compile(corpus, cache, `${corpus.name}-cold`);' \
  'compile(corpus, cache, `${corpus.name}-warmup`);
  const cold = compile(corpus, cache, `${corpus.name}-cold`);'

# The green control. Without it a KPI that always refused would pass both cases
# above while measuring nothing at all.
rm -f "$mutant"
if ! node scripts/incremental_kpi.mjs "$stage2" "$work/green.json" --corpora small \
     >"$work/green.log" 2>&1; then
  echo "[incremental-kpi-test] FAIL: an unmutated run was refused" >&2
  tail -n 12 "$work/green.log" >&2
  failures=$((failures + 1))
else
  echo "[incremental-kpi-test] green ok: unmutated run"
fi

if [ "$failures" -ne 0 ]; then
  echo "[incremental-kpi-test] FAIL: $failures case(s)" >&2
  exit 1
fi
echo "[incremental-kpi-test] ok"
