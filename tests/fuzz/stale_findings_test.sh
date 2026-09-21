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

# Isolated workspace. These probes run the REAL harness, whose startup now
# deletes the findings directory -- pointing them at the shared
# `_build/fuzz/findings` would destroy a developer's campaign inputs and logs
# whenever `release-check` ran (#2955 review).
# Every temporary allocation is CHECKED, and checked IN THIS SHELL. `set -uo
# pipefail` carries no `-e`, so a failed `mktemp -d` -- an inherited TMPDIR
# that is unwritable or missing -- leaves the variable EMPTY and the script
# running; `${VIBE_FUZZ_ROOT:-...}` in run_fuzz.sh triggers on empty as well as
# unset, so the probes would fall back to the shared `_build/fuzz` this
# isolation exists to protect (#2955 review).
#
# The first attempt put the abort in a function called as `V="$(f)"`, where
# `exit 1` ends the SUBSHELL and the parent carries on with V empty -- the
# guard printed its refusal and changed nothing, and a planted finding in the
# shared directory was still destroyed. So the check is inline at each site.
need_dir() { # <var-value> <what>
  if [ -z "${1:-}" ] || [ ! -d "${1:-}" ]; then
    printf '%s: could not allocate a temporary %s (TMPDIR=%s)
' "$(basename "$0")" "$2" "${TMPDIR:-unset}" >&2
    printf '%s: refusing to run -- the probes would fall back to the shared _build/fuzz
' "$(basename "$0")" >&2
    return 1
  fi
}

export VIBE_FUZZ_ROOT="$(mktemp -d 2>/dev/null || true)"
need_dir "${VIBE_FUZZ_ROOT:-}" "fuzz root" || exit 1
FIND="$VIBE_FUZZ_ROOT/findings"
STALE="$FIND/seed_999_STALE_FIXTURE"
# PID-scoped so a concurrent sibling gate cannot collide with or delete it
# (#2955 review). The probe must sit beside run_fuzz.sh, which derives the
# repo root from its own dirname.
PROBE="tests/fuzz/.probe_stale$$.sh"
cleanup() { rm -rf "$VIBE_FUZZ_ROOT" "$PROBE" "$SHIMDIR" 2>/dev/null; }
SHIMDIR=""
trap cleanup EXIT
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
# still present.
#
# Driven by a PATH shim whose `rm` removes nothing and exits nonzero, which
# works on every filesystem and in every container. A `chattr +i` fixture was
# tried first and is the more realistic cause, but it SKIPPED wherever the
# flag is unsupported -- and a skip that leaves `rc` untouched is a gate
# waiving the property it exists to hold, which is this file's own subject.
SHIMDIR="$(mktemp -d 2>/dev/null || true)"
need_dir "${SHIMDIR:-}" "rm shim dir" || exit 1
cat > "$SHIMDIR/rm" <<'SHIM'
#!/bin/sh
# Refuse to remove anything, the way a busy mount or an immutable entry does.
exit 1
SHIM
chmod +x "$SHIMDIR/rm"
if plant; then
  out="$(PATH="$SHIMDIR:$PATH" bash tests/fuzz/run_fuzz.sh --seeds 1..1 --cli "$STAGE2" 2>&1)"; arc=$?
  # The precondition must be real before anything the run says is believed.
  if [ ! -e "$STALE" ]; then
    bad "the shim did NOT block removal -- this case proves nothing"
  else
    say "  ok   the shim genuinely blocks the reset"
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
fi
rm -rf "$SHIMDIR"; SHIMDIR=""
rm -rf "$STALE"

say "=== red: an unresettable SEED LEDGER aborts the run ==="
# The other half of the reset. If `: > "$SEEDS_FILE"` cannot truncate, every
# later append fails too and the final `wc -l` reads 0 while findings/ holds a
# real finding -- the campaign reports success having found something.
# A DIRECTORY in the ledger's place makes the redirection fail on every
# platform, with no chattr and no root-owned fixture needed.
rm -rf "$VIBE_FUZZ_ROOT/failing_seeds.txt"
mkdir -p "$VIBE_FUZZ_ROOT/failing_seeds.txt"
if [ ! -d "$VIBE_FUZZ_ROOT/failing_seeds.txt" ]; then
  bad "the ledger fixture was not created -- this case proves nothing"
else
  say "  ok   the ledger path is a directory, so truncation must fail"
  out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --cli "$STAGE2" 2>&1)"; lrc=$?
  case "$out" in
    *"could not reset"*"failing_seeds"*) say "  ok   the run refused, naming the ledger" ;;
    *) bad "no ledger refusal: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$lrc" -ne 0 ] && say "  ok   nonzero exit ($lrc)" || bad "the run exited 0 with an unresettable ledger"
  case "$out" in
    *"[fuzz] mode="*) bad "the run ANNOUNCED itself and fuzzed anyway" ;;
    *) say "  ok   no campaign was started" ;;
  esac
fi
rm -rf "$VIBE_FUZZ_ROOT/failing_seeds.txt"

say "=== red: an EMPTY ledger whose truncation fails is still rejected ==="
# The shape the directory case cannot produce: the ledger is already an empty
# regular file, so the postcondition alone reads as success, while truncation
# fails and every later append will too -- a real finding reported as
# `0 findings` (#2955 review). Only the truncation's STATUS distinguishes it.
#
# Measured while fixing this: `chmod 0444` does NOT reproduce it as root --
# the redirect succeeds, `[ -w ]` reports writable and appends work, because
# root bypasses the mode bits. `chattr +i` does block root, so that is the
# fixture. Where the flag is unsupported this case cannot run, but the BRANCH
# it exercises is the same one the directory case above covers
# deterministically, so nothing is left unchecked by the skip.
lfile="$VIBE_FUZZ_ROOT/failing_seeds.txt"
rm -rf "$lfile"; : > "$lfile"
if ! command -v chattr >/dev/null 2>&1 || ! chattr +i "$lfile" 2>/dev/null; then
  say "  SKIP chattr +i unavailable here; the directory case above covers this branch"
  rm -f "$lfile"
else
  if ( : > "$lfile" ) 2>/dev/null; then
    bad "the fixture did NOT block truncation -- this case proves nothing"
  elif [ -s "$lfile" ]; then
    bad "the fixture is not empty -- it would be caught by the postcondition, not the status"
  else
    say "  ok   the ledger is empty AND untruncatable, so only the status can tell"
    out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --cli "$STAGE2" 2>&1)"; erc=$?
    case "$out" in
      *"could not reset"*"failing_seeds"*) say "  ok   the run refused, naming the ledger" ;;
      *) bad "no ledger refusal: $(printf '%s' "$out" | tail -1)" ;;
    esac
    [ "$erc" -ne 0 ] && say "  ok   nonzero exit ($erc)" || bad "the run exited 0 with an untruncatable ledger"
    case "$out" in
      *"[fuzz] mode="*) bad "the run ANNOUNCED itself and fuzzed anyway" ;;
      *) say "  ok   no campaign was started" ;;
    esac
  fi
  chattr -i "$lfile" 2>/dev/null
  rm -f "$lfile"
fi

say "=== red: the PRE-FIX harness runs a campaign and leaves it behind ==="
# Reconstruct the old behaviour so the case proves the fix was load-bearing
# rather than merely present.
#
# The mutant must drop the WHOLE reset block -- `rm -rf` AND the guard above.
# Deleting only the `rm -rf` line left the guard in place, so with a stale
# directory planted the mutant hit the guard and exited 2 BEFORE fuzzing: the
# fixture survived because the run was REFUSED, not because a pre-fix harness
# ignored it (#2955 review). The case passed while demonstrating nothing,
# which is the failure this whole file is about.
#
# So survival is accepted only from a mutant that announced a campaign and
# completed it with zero findings -- i.e. a run that genuinely did not care.
probe="$PROBE"
cp tests/fuzz/run_fuzz.sh "$probe"
sed -i.bak '/^rm -rf "\$FIND"$/,/^fi$/d' "$probe" && rm -f "$probe.bak"
if cmp -s tests/fuzz/run_fuzz.sh "$probe"; then
  bad "the mutation changed nothing -- this case would pass while proving nothing"
elif grep -q "findings left there would be read as this run" "$probe"; then
  # Matched against the FINDINGS guard's own wording, not a shared prefix:
  # the seed-ledger guard added later also says "could not reset", so the
  # broader match reported the findings guard as surviving when it had gone.
  bad "the mutation left the findings guard behind -- the mutant would refuse, not fuzz"
else
  say "  ok   the mutant carries neither the reset nor its guard"
  if plant; then
    out="$(bash "$probe" --seeds 1..1 --cli "$STAGE2" 2>&1)"
    case "$out" in
      *"[fuzz] mode="*) say "  ok   pre-fix: the mutant announced a campaign" ;;
      *) bad "pre-fix: no campaign announced -- survival would prove nothing: $(printf '%s' "$out" | tail -1)" ;;
    esac
    case "$out" in
      *"0 findings"*) say "  ok   pre-fix: the campaign completed with 0 findings" ;;
      *) bad "pre-fix: the campaign did not complete cleanly: $(printf '%s' "$out" | tail -1)" ;;
    esac
    if [ -e "$STALE" ]; then
      say "  ok   pre-fix: and the stale finding SURVIVED that clean run"
    else
      bad "pre-fix harness ALSO cleared it -- the green case proves nothing"
    fi
  fi
fi
rm -f "$probe"
rm -rf "$STALE"

if [ "$rc" -eq 0 ]; then say ""; say "[stale-findings-test] ok"; else say ""; say "[stale-findings-test] FAILED"; fi
exit "$rc"
