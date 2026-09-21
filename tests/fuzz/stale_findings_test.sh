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
# A gate must not assume the environment it runs in (#2252). `FUZZ_JOBS` is
# read by run_fuzz.sh and validated before anything this file tests: exported
# as `0` or a non-number by a developer or a runner, every probe would exit at
# job-count validation and the gate would fail for ambient configuration
# rather than for its subject. Cleared here, and each probe passes `--jobs 1`
# explicitly so the value is this file's choice rather than an inheritance.
unset FUZZ_JOBS
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
  out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"
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
  out="$(PATH="$SHIMDIR:$PATH" bash tests/fuzz/run_fuzz.sh --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; arc=$?
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
  # A refusal must not destroy what it is refusing to overwrite: the findings
  # directory holds the previous campaign's repro inputs. Before the reorder,
  # this run exited 2 with the evidence already gone (#2955 review).
  mkdir -p "$FIND/seed_9_REAL_EVIDENCE"
  printf 'repro\n' > "$FIND/seed_9_REAL_EVIDENCE/single.vibe"
  out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; lrc=$?
  if [ -f "$FIND/seed_9_REAL_EVIDENCE/single.vibe" ]; then
    say "  ok   the refusal preserved the previous campaign's evidence"
  else
    bad "the refusal DESTROYED the findings it refused to overwrite"
  fi
  rm -rf "$FIND/seed_9_REAL_EVIDENCE"
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
# Deterministic fault injection, so no host filesystem feature is required.
#
# The property: the harness CONSULTS `seeds_reset_ok`. A real untruncatable
# file is the faithful fixture, but it needs `chattr +i` / `chflags uchg`, and
# neither exists on every filesystem -- on overlayfs as root, `chattr` can
# return EPERM. Making the case FAIL there would break the gate for a reason
# having nothing to do with what it checks; making it SKIP would leave the
# predicate unverified. Injecting the fault instead tests the same branch
# everywhere.
#
# Two copies, differing only in the predicate, each with the truncation forced
# to report failure. The first must refuse; the second must proceed -- which is
# what proves the assertion is the predicate's doing and not something else in
# the script.
inject() { # <name> <extra-sed> -> path
  # Split, not one `local`: a single `local a=$1 b="$a"` expands every word
  # before assigning, so `$b` sees an unbound `$a`. Same slip as earlier in
  # this PR.
  local name="$1"
  local extra="$2"
  local dst="tests/fuzz/.probe_inj${name}$$.sh"
  cp tests/fuzz/run_fuzz.sh "$dst"
  # Force the reset to report failure while STILL leaving an empty regular
  # file, which is exactly the shape an already-empty untruncatable ledger
  # has. Replacing the truncation outright instead would leave no file at all,
  # and `[ ! -f ]` would refuse for that reason -- the control would then look
  # right while proving nothing about the status.
  sed -i.bak 's|^( : > "\$SEEDS_FILE" ) 2>/dev/null .*$|: > "$SEEDS_FILE"; seeds_reset_ok=0|' "$dst" && rm -f "$dst.bak"
  if [ -n "$extra" ]; then
    sed -i.bak "$extra" "$dst" && rm -f "$dst.bak"
  fi
  printf '%s\n' "$dst"
}

say "=== red: the ledger guard CONSULTS the truncation status (fault-injected) ==="
inj_keep="$(inject keep "")"
if grep -q 'seeds_reset_ok=0' "$inj_keep" && grep -q '\[ "\$seeds_reset_ok" -eq 0 \]' "$inj_keep"; then
  say "  ok   fault injected, predicate still present"
  out="$(bash "$inj_keep" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; irc=$?
  case "$out" in
    *"could not reset"*"failing_seeds"*) say "  ok   with the predicate, a failed truncation REFUSES" ;;
    *) bad "with the predicate present the run did not refuse: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$irc" -ne 0 ] && say "  ok   nonzero exit ($irc)" || bad "exited 0 despite a failed truncation"
else
  bad "the injection did not apply -- this case would prove nothing"
fi
rm -f "$inj_keep"

# The control: same injected fault, predicate deleted. It must PROCEED, which
# is what makes the case above attributable to the predicate.
inj_drop="$(inject drop 's@if \[ "\$seeds_reset_ok" -eq 0 \] || @if @')"
if grep -q 'seeds_reset_ok=0' "$inj_drop" && ! grep -q '\[ "\$seeds_reset_ok" -eq 0 \]' "$inj_drop"; then
  say "  ok   control staged: same fault, predicate removed"
  out="$(bash "$inj_drop" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; crc=$?
  case "$out" in
    *"0 findings"*) say "  ok   without the predicate it runs and reports 0 -- the silently-wrong outcome" ;;
    *) bad "control did not complete a campaign: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$crc" -eq 0 ] && say "  ok   control exits 0, so the refusal above is the predicate's doing" || bad "control exited $crc"
else
  bad "the control mutation did not apply -- the case above is unattributed"
fi
rm -f "$inj_drop"

say "=== red: the workspace guard is CONSULTED (fault-injected) ==="
# Same paired shape as the ledger case, for the other unchecked step: if the
# workspace mkdir fails, a campaign could announce itself and finish with
# `0 findings` and no findings directory to read.
inject_ws() { # <name> <extra-sed> -> path
  local name="$1"
  local extra="$2"
  local dst="tests/fuzz/.probe_ws${name}$$.sh"
  cp tests/fuzz/run_fuzz.sh "$dst"
  # Make the recreation a no-op, as a full disk would.
  sed -i.bak 's@^mkdir -p "\$WORK" "\$FIND" 2>/dev/null .*$@:@' "$dst" && rm -f "$dst.bak"
  if [ -n "$extra" ]; then sed -i.bak "$extra" "$dst" && rm -f "$dst.bak"; fi
  printf '%s\n' "$dst"
}

ws_keep="$(inject_ws keep "")"
if grep -q '\[ ! -d "\$WORK" \] || \[ ! -d "\$FIND" \]' "$ws_keep"; then
  say "  ok   fault injected, workspace guard still present"
  out="$(bash "$ws_keep" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; wrc=$?
  case "$out" in
    *"could not create the workspace"*) say "  ok   with the guard, a failed mkdir REFUSES" ;;
    *) bad "with the guard present the run did not refuse: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$wrc" -ne 0 ] && say "  ok   nonzero exit ($wrc)" || bad "exited 0 with no findings directory"
else
  bad "the workspace injection did not apply -- this case would prove nothing"
fi
rm -f "$ws_keep"

ws_drop="$(inject_ws drop 's@^if \[ ! -d "\$WORK" \] || \[ ! -d "\$FIND" \]; then@if false; then@')"
if grep -q 'if false; then' "$ws_drop"; then
  say "  ok   control staged: same fault, guard disabled"
  # The control must reach the silently-wrong OUTCOME, not merely get past the
  # guard. Checking only for the banner would also pass for a mutant that
  # announced itself and then died in generation or compilation, which proves
  # execution crossed the guard and nothing about a clean `0 findings` result
  # (#2955 review). The ledger and pre-fix controls already required both;
  # this one did not.
  out="$(bash "$ws_drop" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; wcrc=$?
  case "$out" in
    *"[fuzz] mode="*) say "  ok   without the guard it announces a campaign" ;;
    *) bad "control did not announce a campaign: $(printf '%s' "$out" | tail -1)" ;;
  esac
  case "$out" in
    *"0 findings"*) say "  ok   and completes with 0 findings -- the silently-wrong outcome" ;;
    *) bad "control did not complete a campaign: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$wcrc" -eq 0 ] && say "  ok   control exits 0, so the refusal above is the guard's doing" || bad "control exited $wcrc"
else
  bad "the control mutation did not apply -- the case above is unattributed"
fi
rm -f "$ws_drop"

say "=== red: a malformed or zero-padded range must not touch the findings ==="
# Two shapes, one property: nothing destructive happens before the range is
# known good. `typo` has no `..`; `08..09` is digit-only and passes `[ -le ]`
# but is an invalid octal literal to `$(( ))`, so it used to clear both
# records and then die at `total=$((B - A + 1))` (#2955 review).
for rng in typo 9..1; do
  rm -rf "$FIND/seed_9_RANGE"; mkdir -p "$FIND/seed_9_RANGE"
  printf 'repro\n' > "$FIND/seed_9_RANGE/single.vibe"
  out="$(bash tests/fuzz/run_fuzz.sh --seeds "$rng" --jobs 1 --cli "$STAGE2" 2>&1)"; rrc=$?
  case "$out" in
    *"--seeds"*) say "  ok   '$rng' rejected, naming --seeds" ;;
    *) bad "'$rng' produced no --seeds diagnostic: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$rrc" -ne 0 ] && say "  ok   '$rng' exits nonzero ($rrc)" || bad "'$rng' exited 0"
  if [ -f "$FIND/seed_9_RANGE/single.vibe" ]; then
    say "  ok   '$rng' left the previous findings intact"
  else
    bad "'$rng' DESTROYED the previous findings before validating the range"
  fi
  rm -rf "$FIND/seed_9_RANGE"
done

# Zero-padded endpoints are accepted and read as base 10, not octal.
out="$(bash tests/fuzz/run_fuzz.sh --seeds 08..09 --jobs 1 --cli "$STAGE2" 2>&1)"; zrc=$?
case "$out" in
  *"seeds=8..9"*) say "  ok   '08..09' normalizes to 8..9" ;;
  *) bad "'08..09' was not normalized: $(printf '%s' "$out" | head -1)" ;;
esac
case "$out" in
  *"done: 2 seeds"*) say "  ok   and completes the campaign" ;;
  *) bad "'08..09' did not complete: $(printf '%s' "$out" | tail -1)" ;;
esac
[ "$zrc" -eq 0 ] && say "  ok   exits 0" || bad "'08..09' exited $zrc"

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
    out="$(bash "$probe" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"
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
