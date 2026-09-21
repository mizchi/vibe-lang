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
  # FAIL, not skip. `resolve_stage2_strict` refuses rather than degrading
  # precisely so a measurement cannot come from the wrong compiler; turning
  # that refusal into a green skip would make "could not run" and "ran and
  # passed" the same exit code, which is the failure this whole gate is about.
  # CI always has one via `deps { selfhostGeneration }`.
  say "[stale-findings-test] FAILED: no generation for HEAD"
  say "  Build one with 'pkf run generation', or name the artifact with"
  say "  VIBE_STAGE2_WASM=<path>. Refusing to pass without having run."
  exit 1
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

say "=== red: an unresettable findings dir ABORTS the run ==="
# The #2955 review case. `set -uo pipefail` carries no `-e`, so a failed
# `rm -rf` would pass unnoticed and `mkdir -p` would succeed against the
# surviving directory -- a clean campaign reporting 0 findings with stale ones
# still present. Made real here with an immutable file, which blocks unlink
# even for root, so the guard is SHOWN to fire rather than asserted.
if ! command -v chattr >/dev/null 2>&1; then
  say "  SKIP chattr unavailable -- cannot make the reset fail for real here"
else
  rm -rf "$STALE"; mkdir -p "$STALE"; : > "$STALE/immutable"
  if ! chattr +i "$STALE/immutable" 2>/dev/null; then
    rm -rf "$STALE" 2>/dev/null
    say "  SKIP chattr +i not permitted on this filesystem"
  else
    # Confirm the block is real before believing anything the run reports.
    rm -rf "$FIND" 2>/dev/null
    if [ ! -e "$STALE" ]; then
      bad "the immutable fixture did NOT block removal -- this case proves nothing"
      chattr -i "$STALE/immutable" 2>/dev/null
    else
      say "  ok   the fixture genuinely blocks rm -rf"
      out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --cli "$STAGE2" 2>&1)"; arc=$?
      case "$out" in
        *"could not reset"*) say "  ok   the run refused, naming the reset" ;;
        *) bad "no refusal message: $(printf '%s' "$out" | tail -1)" ;;
      esac
      [ "$arc" -ne 0 ] && say "  ok   nonzero exit ($arc)" || bad "the run exited 0 with an unreset findings dir"
      case "$out" in
        *"[fuzz] mode="*) bad "the run ANNOUNCED itself and fuzzed anyway" ;;
        *) say "  ok   no campaign was started" ;;
      esac
    fi
    chattr -i "$STALE/immutable" 2>/dev/null
    rm -rf "$STALE"
  fi
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
