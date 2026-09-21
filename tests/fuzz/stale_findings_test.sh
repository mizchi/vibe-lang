#!/usr/bin/env bash
# run_fuzz.sh must leave `_build/fuzz/findings/` describing THIS run (#2954).
#
# The harness truncates `failing_seeds.txt` at startup. It did not clear
# `findings/`, so a finding directory from an earlier invocation survived and
# read as a current one. `findings/` is what a person opens to learn WHAT was
# found; the summary line gives only a count.
#
# Red-tested by running the PRE-FIX harness against the same fixture and
# asserting the stale directory survives there -- a test that only exercises
# the fixed code proves the fix is present, not that it was needed.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"

FIND=_build/fuzz/findings
STALE="$FIND/seed_999_STALE_FIXTURE"
rc=0
say() { printf '%s\n' "$*"; }
bad() { say "  FAIL $*"; rc=1; }

STAGE2="$(bash -c '. scripts/resolve_stage2.sh; resolve_stage2_strict stale-findings-test "${VIBE_STAGE2_WASM:-}"' 2>/dev/null)"
if [ -z "$STAGE2" ] || [ ! -f "$STAGE2" ]; then
  say "[stale-findings-test] SKIP: no generation for HEAD; build one with 'pkf run generation'"
  say "  (refusing to measure another compiler -- see scripts/resolve_stage2.sh)"
  exit 0
fi

plant() {
  rm -rf "$STALE"; mkdir -p "$STALE"
  printf 'planted by %s\n' "$(basename "$0")" > "$STALE/note.txt"
  [ -f "$STALE/note.txt" ] || { bad "fixture could not be planted"; return 1; }
}

say "=== green: a clean run clears a stale finding ==="
if plant; then
  out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --cli "$STAGE2" 2>&1)"
  if [ -e "$STALE" ]; then
    bad "the stale finding SURVIVED a run: $STALE"
  else
    say "  ok   the stale finding is gone"
  fi
  case "$out" in
    *"0 findings"*) say "  ok   the run itself reported 0 findings" ;;
    *) bad "the probe run did not report 0 findings: $(printf '%s' "$out" | tail -1)" ;;
  esac
fi

say "=== red: the PRE-FIX harness leaves it behind ==="
# Reconstruct the old behaviour by removing the reset line, so the case proves
# the fix was load-bearing rather than merely present.
probe=tests/fuzz/.probe_prefix.sh
cp tests/fuzz/run_fuzz.sh "$probe"
sed -i.bak '/^rm -rf "\$FIND"$/d' "$probe" && rm -f "$probe.bak"
if cmp -s tests/fuzz/run_fuzz.sh "$probe"; then
  bad "the mutation changed nothing -- this case would pass while proving nothing"
else
  if plant; then
    bash "$probe" --seeds 1..1 --cli "$STAGE2" >/dev/null 2>&1
    if [ -e "$STALE" ]; then
      say "  ok   pre-fix: the stale finding survives, as it did before #2954"
    else
      bad "pre-fix harness ALSO cleared it -- the green case proves nothing"
    fi
  fi
fi
rm -f "$probe"
rm -rf "$STALE"

if [ "$rc" -eq 0 ]; then say ""; say "[stale-findings-test] ok"; else say ""; say "[stale-findings-test] FAILED"; fi
exit "$rc"
