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
# PID-scoped, so the glob can never reach a concurrent sibling's probes. The
# injected copies are removed at each case too; this is the crash path.
cleanup() {
  rm -rf "$VIBE_FUZZ_ROOT" "$PROBE" "$SHIMDIR" 2>/dev/null
  rm -f tests/fuzz/.probe_*"$$".sh tests/fuzz/.probe_*"$$".sh.bak 2>/dev/null
}
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
  # The reset moves the old findings aside before recreating the workspace, so
  # a successful run must also have removed the holding copy -- otherwise every
  # campaign leaves one more `findings.prev.<pid>` behind, and a person reading
  # the workspace finds several directories of findings with nothing saying
  # which is this run's.
  if ls -d "$VIBE_FUZZ_ROOT"/findings.prev.* >/dev/null 2>&1; then
    bad "a holding copy survived a successful run: $(ls -d "$VIBE_FUZZ_ROOT"/findings.prev.* | tr '\n' ' ')"
  else
    say "  ok   no holding copy was left behind"
  fi
fi

say "=== red: a findings dir that cannot be MOVED ASIDE aborts the run ==="
# The #2955 review case. `set -uo pipefail` carries no `-e`, so a failed reset
# would pass unnoticed and `mkdir -p` would succeed against the surviving
# directory -- a clean campaign reporting 0 findings with stale ones still
# present.
#
# The reset moves the findings aside instead of deleting them (a refusal must
# not destroy what it refuses to overwrite, #2955 review), so the operation
# that can fail is `mv`, and that is what this shim blocks. It used to shim
# `rm`; under the current ordering a failing `rm` is NOT fatal -- the findings
# are already out of `$FIND` by then, so nothing reads them as this run's --
# and shimming it would assert a refusal the harness no longer owes.
#
# A PATH shim works on every filesystem and in every container. A `chattr +i`
# fixture was tried first and is the more realistic cause, but it SKIPPED
# wherever the flag is unsupported -- and a skip that leaves `rc` untouched is
# a gate waiving the property it exists to hold, which is this file's own
# subject.
SHIMDIR="$(mktemp -d 2>/dev/null || true)"
need_dir "${SHIMDIR:-}" "mv shim dir" || exit 1
cat > "$SHIMDIR/mv" <<'SHIM'
#!/bin/sh
# Refuse to move anything, the way a busy mount or an immutable entry does.
exit 1
SHIM
chmod +x "$SHIMDIR/mv"
if plant; then
  out="$(PATH="$SHIMDIR:$PATH" bash tests/fuzz/run_fuzz.sh --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; arc=$?
  # The precondition must be real before anything the run says is believed.
  if [ ! -e "$STALE" ]; then
    bad "the shim did NOT block the move -- this case proves nothing"
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
    *"could not create or write the workspace"*) say "  ok   with the guard, a failed mkdir REFUSES" ;;
    *) bad "with the guard present the run did not refuse: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$wrc" -ne 0 ] && say "  ok   nonzero exit ($wrc)" || bad "exited 0 with no findings directory"
else
  bad "the workspace injection did not apply -- this case would prove nothing"
fi
rm -f "$ws_keep"

ws_drop="$(inject_ws drop 's@^if \[ ! -d "\$WORK" \] || \[ ! -d "\$FIND" \] || \[ "\$ws_writable" -eq 0 \]; then@if false; then@')"
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

say "=== red: a failed workspace recreation PRESERVES the previous findings ==="
# The same rule as the ledger ordering above, one step later: a refusal must
# not destroy what it refuses to overwrite. Measured before the fix with a
# regular file in `work`'s place -- `could not create or write the workspace`,
# exit 2,
# and `findings/seed_9_REAL_EVIDENCE/single.vibe` gone for good (#2955 review).
#
# The fixture needs no fault injection and is deterministic on every platform:
# `mkdir -p` cannot create `work` where a regular file already sits, so the
# recreation fails at a point the findings reset has already passed.
plant_evidence() {
  rm -rf "$FIND" "$VIBE_FUZZ_ROOT/work"
  mkdir -p "$FIND/seed_9_REAL_EVIDENCE"
  printf 'repro\n' > "$FIND/seed_9_REAL_EVIDENCE/single.vibe"
  : > "$VIBE_FUZZ_ROOT/work"
  if [ ! -f "$FIND/seed_9_REAL_EVIDENCE/single.vibe" ] || [ ! -f "$VIBE_FUZZ_ROOT/work" ]; then
    bad "the workspace-collision fixture was not staged -- this case proves nothing"
    return 1
  fi
}

if plant_evidence; then
  say "  ok   fixture staged: a regular file occupies the work directory's path"
  out="$(bash tests/fuzz/run_fuzz.sh --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; erc=$?
  case "$out" in
    *"could not create or write the workspace"*) say "  ok   the run refused, naming the workspace" ;;
    *) bad "no workspace refusal: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$erc" -ne 0 ] && say "  ok   nonzero exit ($erc)" || bad "the run exited 0 with no workspace"
  case "$out" in
    *"[fuzz] mode="*) bad "the run ANNOUNCED itself and fuzzed anyway" ;;
    *) say "  ok   no campaign was started" ;;
  esac
  if [ -f "$FIND/seed_9_REAL_EVIDENCE/single.vibe" ]; then
    say "  ok   the refusal preserved the previous campaign's evidence"
  else
    bad "the refusal DESTROYED the findings it refused to overwrite"
  fi
fi

# The pairing: the same fixture against a harness that DELETES instead of
# moving aside. It must lose the evidence -- otherwise the case above would
# pass for some reason other than the ordering, and prove nothing.
wsdel="tests/fuzz/.probe_wsdel$$.sh"
cp tests/fuzz/run_fuzz.sh "$wsdel"
sed -i.bak 's@^  mv "\$FIND" "\$FIND_PREV" 2>/dev/null .*$@  rm -rf "$FIND"@' "$wsdel" && rm -f "$wsdel.bak"
if grep -q '^  rm -rf "\$FIND"$' "$wsdel"; then
  say "  ok   pre-fix mutant staged: the reset deletes instead of moving aside"
  if plant_evidence; then
    out="$(bash "$wsdel" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"
    case "$out" in
      *"could not create or write the workspace"*) say "  ok   pre-fix: it refuses at the same point" ;;
      *) bad "pre-fix: the mutant did not reach the workspace refusal: $(printf '%s' "$out" | tail -1)" ;;
    esac
    if [ -f "$FIND/seed_9_REAL_EVIDENCE/single.vibe" ]; then
      bad "pre-fix: the evidence survived deletion too -- the case above proves nothing"
    else
      say "  ok   pre-fix: the evidence is gone, so preserving it is the fix's doing"
    fi
  fi
else
  bad "the pre-fix mutation did not apply -- the case above is unattributed"
fi
rm -f "$wsdel"
rm -rf "$FIND" "$VIBE_FUZZ_ROOT/work"

say "=== red: an existing holding copy is NEVER destroyed ==="
# The reset moves the findings to `findings.prev.<pid>.<n>`. `$$` is not unique
# across containers -- a fresh one restarts PIDs low -- so a run whose holding
# copy survived (killed mid-reset, or a failed restoration that SAID the
# evidence was left there) can hand its name to a later run. Clearing that name
# first would destroy exactly what the message promised was kept.
#
# The pid is pinned to a fixed token in the probe, because a test cannot know
# the harness's own `$$` in advance; the code path under test -- picking the
# next FREE suffix -- is unchanged by that substitution.
hold="tests/fuzz/.probe_hold$$.sh"
cp tests/fuzz/run_fuzz.sh "$hold"
sed -i.bak 's@\$FIND\.prev\.\$\$\.\$prev_n@$FIND.prev.FIXEDPID.$prev_n@g' "$hold" && rm -f "$hold.bak"
HOLD0="$FIND.prev.FIXEDPID.0"
plant_holding() {
  rm -rf "$FIND" "$HOLD0" "$FIND.prev.FIXEDPID.1"
  mkdir -p "$HOLD0/seed_7_HELD" "$FIND/seed_8_STALE"
  printf 'held\n' > "$HOLD0/seed_7_HELD/single.vibe"
  printf 'stale\n' > "$FIND/seed_8_STALE/single.vibe"
  if [ ! -f "$HOLD0/seed_7_HELD/single.vibe" ] || [ ! -f "$FIND/seed_8_STALE/single.vibe" ]; then
    bad "the holding fixture was not staged -- this case proves nothing"
    return 1
  fi
}
if grep -q 'FIND.prev.FIXEDPID' "$hold"; then
  say "  ok   probe staged with a fixed holding pid"
  if plant_holding; then
    out="$(bash "$hold" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"
    case "$out" in
      *"0 findings"*) say "  ok   the run completed" ;;
      *) bad "the probe run did not complete: $(printf '%s' "$out" | tail -1)" ;;
    esac
    if [ -f "$HOLD0/seed_7_HELD/single.vibe" ]; then
      say "  ok   the earlier run's holding copy is untouched"
    else
      bad "the run DESTROYED an earlier run's holding copy at $HOLD0"
    fi
    if [ -e "$FIND/seed_8_STALE" ]; then
      bad "the stale finding survived -- the run did not reset at all"
    else
      say "  ok   and this run's findings dir was still reset"
    fi
  fi
else
  bad "the holding-pid substitution did not apply -- this case would prove nothing"
fi

# The pairing: clear the name instead of choosing a free one, which is what the
# first version of this fix did.
sed -i.bak 's@^  if \[ ! -e "\$FIND.prev.FIXEDPID.\$prev_n" \]; then FIND_PREV=.*$@  rm -rf "$FIND.prev.FIXEDPID.$prev_n"; FIND_PREV="$FIND.prev.FIXEDPID.$prev_n"; break@' "$hold" && rm -f "$hold.bak"
if grep -q '^  rm -rf "\$FIND.prev.FIXEDPID.\$prev_n"' "$hold"; then
  say "  ok   pre-fix mutant staged: the holding name is cleared, not chosen free"
  if plant_holding; then
    out="$(bash "$hold" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"
    case "$out" in
      *"0 findings"*) say "  ok   pre-fix: it completes the same campaign" ;;
      *) bad "pre-fix: the mutant did not complete: $(printf '%s' "$out" | tail -1)" ;;
    esac
    if [ -f "$HOLD0/seed_7_HELD/single.vibe" ]; then
      bad "pre-fix: the holding copy survived too -- the case above proves nothing"
    else
      say "  ok   pre-fix: the holding copy is gone, so keeping it is the fix's doing"
    fi
  fi
else
  bad "the pre-fix holding mutation did not apply -- the case above is unattributed"
fi
rm -f "$hold"
rm -rf "$FIND" "$HOLD0" "$FIND.prev.FIXEDPID.1"

say "=== red: an existing but UNWRITABLE workspace is refused (fault-injected) ==="
# `[ -d ]` asks whether the directory exists; the run needs it WRITABLE, and
# the two part company where it matters -- root-owned residue from another
# container makes `mkdir -p` succeed and the `-d` test pass, so the holding
# copy is deleted and the first seed then cannot create anything (#2955
# review).
#
# Injected rather than staged with real permissions: these gates run as root
# in CI, where the mode bits do not bind (measured earlier in this PR --
# `chmod 0444` leaves a file writable for root), and `chattr +i` is
# unsupported on some filesystems. Injection exercises the same branch
# everywhere, which is why the ledger predicate above is tested this way too.
inject_ws_probe() { # <name> <extra-sed> -> path
  local nm="$1"
  local extra="$2"
  local dst="tests/fuzz/.probe_wsw${nm}$$.sh"
  cp tests/fuzz/run_fuzz.sh "$dst"
  # The probe reports failure while the directories are genuinely fine, so
  # the ONLY thing that can refuse is the predicate under test.
  sed -i.bak 's@^  ( : > "\$ws_probe" ) 2>/dev/null || ws_writable=0$@  ws_writable=0@' "$dst" && rm -f "$dst.bak"
  if [ -n "$extra" ]; then sed -i.bak "$extra" "$dst" && rm -f "$dst.bak"; fi
  printf '%s\n' "$dst"
}

wsw_keep="$(inject_ws_probe keep "")"
if grep -q '\[ "\$ws_writable" -eq 0 \]' "$wsw_keep" && grep -q '^  ws_writable=0$' "$wsw_keep"; then
  say "  ok   fault injected, writability predicate still present"
  rm -rf "$FIND"; mkdir -p "$FIND/seed_9_REAL_EVIDENCE"
  printf 'repro\n' > "$FIND/seed_9_REAL_EVIDENCE/single.vibe"
  out="$(bash "$wsw_keep" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; wwrc=$?
  case "$out" in
    *"could not create or write the workspace"*) say "  ok   an unwritable workspace REFUSES" ;;
    *) bad "no writability refusal: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$wwrc" -ne 0 ] && say "  ok   nonzero exit ($wwrc)" || bad "exited 0 with an unwritable workspace"
  if [ -f "$FIND/seed_9_REAL_EVIDENCE/single.vibe" ]; then
    say "  ok   and the refusal preserved the previous campaign's evidence"
  else
    bad "the refusal DESTROYED the findings it refused to overwrite"
  fi
else
  bad "the writability injection did not apply -- this case would prove nothing"
fi
rm -f "$wsw_keep"

# The control: same fault, predicate dropped from the guard. It must proceed,
# which is what makes the refusal above the predicate's doing.
wsw_drop="$(inject_ws_probe drop 's@ || \[ "\$ws_writable" -eq 0 \]; then@; then@')"
if ! grep -q '\[ "\$ws_writable" -eq 0 \]; then' "$wsw_drop"; then
  say "  ok   control staged: same fault, predicate removed from the guard"
  rm -rf "$FIND"
  out="$(bash "$wsw_drop" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; wcrc2=$?
  case "$out" in
    *", 0 findings"*) say "  ok   without it the run proceeds -- so the refusal is the predicate's" ;;
    *) bad "control did not complete a campaign: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$wcrc2" -eq 0 ] && say "  ok   control exits 0" || bad "control exited $wcrc2"
else
  bad "the control mutation did not apply -- the case above is unattributed"
fi
rm -f "$wsw_drop"
rm -rf "$FIND"

say "=== red: no GNU timeout falls back to a watchdog that still BOUNDS ==="
# `timeout` is absent from a stock macOS (BSD userland; coreutils installs it
# as `gtimeout`), and this gate runs the real harness from `release-check`.
# With neither binary present every lane of every seed was a command-not-found
# -- 127, no wasm, no diag -- which `compile` reads as COMPILE_CRASH, so the
# campaign reported a compiler bug per generated program (#2955 review).
#
# The fallback keeps the BOUND rather than dropping it: 124 is the only thing
# separating COMPILE_HANG / RUN_HANG from a crash, so an unbounded lane would
# delete two finding classes and a real hang would wedge the campaign. The
# cases below check the watchdog against timeout(1)'s contract, then run a real
# campaign through it.
#
# The probe removes both candidates by NAME rather than by emptying PATH, so
# everything else the harness needs still resolves.
tprobe="tests/fuzz/.probe_to$$.sh"
tlib="tests/fuzz/.probe_tolib$$.sh"
wdcase="tests/fuzz/.probe_wdcase$$.sh"
cp tests/fuzz/run_fuzz.sh "$tprobe"
cp tests/fuzz/lib_oracle.sh "$tlib"
sed -i.bak "s@lib_oracle.sh\"@$(basename "$tlib")\"@" "$tprobe" && rm -f "$tprobe.bak"
sed -i.bak 's@command -v timeout @command -v vibe_absent_timeout @; s@command -v gtimeout @command -v vibe_absent_gtimeout @' "$tlib" && rm -f "$tlib.bak"

cat > "$wdcase" <<'WD'
# One watchdog_run case per invocation, with the shell fallback forced on.
# Prints "rc=<status> elapsed=<seconds>".
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
CLI="x"
# shellcheck disable=SC1090
. "$1"
TIMEOUT_BIN=""
t0=$(date +%s)
case "$2" in
  hang)       watchdog_run 2 sleep 12 >/dev/null 2>&1; rc=$? ;;
  status)     watchdog_run 5 sh -c 'exit 7' >/dev/null 2>&1; rc=$? ;;
  self_term)  watchdog_run 5 sh -c 'kill -TERM $$' >/dev/null 2>&1; rc=$? ;;
  # The shape every call site here actually has: a wrapper that spawns the
  # real workload. Signalling only the direct child leaves the grandchild
  # holding the command substitution's pipe, so the answer is 124 and the
  # WALL CLOCK is the child's full lifetime -- a bound that does not bind
  # (#2955 review).
  grandchild) out=$(watchdog_run 2 bash -c 'bash -c "sleep 12" & wait' 2>/dev/null); rc=$? ;;
  # The marker directory is gone, as it would be if the filesystem filled
  # after the fallback was selected. There is no evidence left to decide with,
  # so the call must say so (125) rather than guess either way.
  hang_nomarker)
    WATCHDOG_DIR="/nonexistent-wd-$$"
    ( watchdog_run 2 sleep 12 ) >/dev/null 2>&1; rc=$? ;;
  self_term_nomarker)
    WATCHDOG_DIR="/nonexistent-wd-$$"
    ( watchdog_run 5 sh -c 'kill -TERM $$' ) >/dev/null 2>&1; rc=$? ;;
  # The rounded-clock case. An earlier version cross-checked elapsed time
  # against the bound, and `date +%s` resolution made a program that kills
  # itself at 1.2s under a 2s bound answer 124 -- measured, 2 runs in 8. Run
  # repeatedly, because the wrong answer was INTERMITTENT: a single sample
  # passed most of the time while the defect was present (#2955 review).
  # Seeds run concurrently, and each lane calls this. Two overlapping calls
  # must not share a marker: the first to finish removes it, and the second
  # then reads its absence as its own bound -- a program that completed
  # normally reported as a hang.
  concurrent)
    watchdog_run 9 sh -c 'sleep 1' >/dev/null 2>&1 &
    c1=$!
    watchdog_run 9 sh -c 'sleep 3' >/dev/null 2>&1 &
    c2=$!
    wait "$c1"; r1=$?
    wait "$c2"; r2=$?
    rc=0
    [ "$r1" = "124" ] && rc=124
    [ "$r2" = "124" ] && rc=124 ;;
  late_self_term)
    rc=0
    n=0
    while [ "$n" -lt 8 ]; do
      watchdog_run 2 sh -c 'sleep 1.2; kill -TERM $$' >/dev/null 2>&1
      one=$?
      [ "$one" = "124" ] && rc=124
      n=$((n + 1))
    done
    [ "$rc" = "124" ] || rc=143 ;;
  *) echo "unknown case: $2" >&2; exit 2 ;;
esac
t1=$(date +%s)
echo "rc=$rc elapsed=$((t1 - t0))"
WD

wd_expect() { # <case> <want-rc> <max-seconds> <why>
  local c="$1"
  local want="$2"
  local maxs="$3"
  local why="$4"
  local line
  line="$(bash "$wdcase" "$ROOT/$tlib" "$c" 2>&1 | tail -1)"
  local rc="${line#rc=}"
  rc="${rc%% *}"
  local el="${line##*elapsed=}"
  case "$rc$el" in
    *[!0-9]*) bad "$c: unreadable result '$line'"; return ;;
  esac
  if [ "$rc" = "$want" ] && [ "$el" -le "$maxs" ]; then
    say "  ok   $c: rc=$rc in ${el}s -- $why"
  else
    bad "$c: got rc=$rc in ${el}s, want rc=$want within ${maxs}s -- $why"
  fi
}

if grep -q "$(basename "$tlib")" "$tprobe" && grep -q 'vibe_absent_gtimeout' "$tlib"; then
  say "  ok   probe staged: neither timeout binary resolves"
  wd_expect hang 124 8 "the bound is reached, and reported the way timeout(1) reports it"
  wd_expect status 7 8 "a command's own status passes through untouched"
  wd_expect self_term 143 8 "a program the OOM killer TERMs is not relabelled a hang"
  wd_expect grandchild 124 8 "the whole process group is signalled, so the bound binds"
  wd_expect hang_nomarker 125 8 "with no marker there is no evidence, so it refuses rather than guessing"
  wd_expect self_term_nomarker 125 8 "and refuses the same way rather than passing the signal off as its own"
  wd_expect late_self_term 143 40 "a late self-kill under the bound is never relabelled (8 runs, none 124)"
  wd_expect concurrent 0 20 "overlapping calls do not share a marker"
  # Paired: a marker name that is NOT unique per call. `$$` is shared by every
  # background seed, and a bash 3.2 subshell inherits the parent's RANDOM
  # sequence, so this is what composing the name instead of allocating it
  # amounts to -- the second call reports a hang for a program that finished.
  collidelib="tests/fuzz/.probe_collidelib$$.sh"
  cp "$tlib" "$collidelib"
  sed -i.bak 's@^  marker="\$(mktemp .*$@  marker="${WATCHDOG_DIR:-/nonexistent}/wd.shared"; ( : > "$marker" ) 2>/dev/null@' "$collidelib" && rm -f "$collidelib.bak"
  if grep -q 'wd.shared' "$collidelib"; then
    cline="$(bash "$wdcase" "$ROOT/$collidelib" concurrent 2>&1 | tail -1)"
    case "$cline" in
      rc=124*) say "  ok   pre-fix: a shared marker answers 124 for a completed program" ;;
      *) bad "pre-fix: a shared marker did not collide ($cline) -- the case above proves nothing" ;;
    esac
  else
    bad "the shared-marker mutation did not apply -- the case above is unattributed"
  fi
  rm -f "$collidelib"
  # The behavioural case above is INTERMITTENT by nature -- the defect it
  # guards showed up in 2 runs of 8 -- so the rule is also asserted
  # lexically, where it is decidable: ownership of a kill comes from state the
  # watchdog wrote, never from reading the clock.
  # Comments are stripped first. Written without that, this matched the
  # sentence in lib_oracle.sh that EXPLAINS why the clock is not consulted --
  # a checker reading its own documentation as evidence, which is the trap
  # AGENTS.md records being walked into twice in #2138.
  if sed 's/#.*$//' "$tlib" | grep -q 'date +%s'; then
    bad "the oracle consults wall-clock time again; rounded seconds cannot decide who killed the child"
  else
    say "  ok   the classification reads no clock (comments stripped first)"
  fi
  # And the directory it allocates is cleaned up by the process that made it:
  # reduce.py starts a fresh classify.sh per oracle call, 4000 by default.
  tmphome="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$tmphome" ] || [ ! -d "$tmphome" ]; then
    bad "could not allocate a TMPDIR for the cleanup case"
  else
    # DIRECTORIES only. Counting every entry also counted the node runner's
    # flag cache -- a file it writes into TMPDIR by design -- so the case
    # failed for something that is not a leak.
    # A shell glob, not `find`: no external command to fail, and so nothing to
    # swallow. The first version redirected `find`'s diagnostic away and piped
    # an empty result to `wc`, so ANY failure counted as 0 -- the count could
    # not tell "no directories" from "the command did not run", and this file's
    # own subject is checks that cannot fail (#2955 review). (`-maxdepth` is
    # not the portability problem it was reported as: FreeBSD find has both
    # primaries, and 15 scripts here already use them, several on the macOS
    # lanes. Removing the external command is still the better answer.)
    count_dirs() {
      cd_n=0
      for cd_e in "$1"/*; do
        [ -d "$cd_e" ] && cd_n=$((cd_n + 1))
      done
      printf '%s' "$cd_n"
    }
    rm -rf "$FIND"
    TMPDIR="$tmphome" bash "$tprobe" --seeds 1..1 --jobs 1 --cli "$STAGE2" >/dev/null 2>&1
    left="$(count_dirs "$tmphome")"
    if [ "$left" = "0" ]; then
      say "  ok   the fallback left no watchdog directory behind"
    else
      bad "the fallback leaked $left director(ies) into TMPDIR"
    fi
    # Proven able to fail: the same probe with the cleanup trap removed must
    # leave one behind, or this case is checking nothing.
    leaklib="tests/fuzz/.probe_leaklib$$.sh"
    cp "$tlib" "$leaklib"
    sed -i.bak "s@^  trap 'rm -rf \"\$WATCHDOG_DIR\"' EXIT\$@  :@" "$leaklib" && rm -f "$leaklib.bak"
    leakprobe="tests/fuzz/.probe_leak$$.sh"
    cp "$tprobe" "$leakprobe"
    sed -i.bak "s@$(basename "$tlib")\"@$(basename "$leaklib")\"@" "$leakprobe" && rm -f "$leakprobe.bak"
    if grep -q "trap 'rm -rf" "$leaklib"; then
      bad "the cleanup-trap mutation did not apply -- the case above is unattributed"
    else
      rm -rf "$FIND"
      TMPDIR="$tmphome" bash "$leakprobe" --seeds 1..1 --jobs 1 --cli "$STAGE2" >/dev/null 2>&1
      if [ "$(count_dirs "$tmphome")" = "0" ]; then
        bad "without the trap nothing was left either -- the case above proves nothing"
      else
        say "  ok   without the trap one IS left, so the cleanup is the trap's doing"
      fi
    fi
    rm -f "$leaklib" "$leakprobe"
    rm -rf "$tmphome"
  fi
  # The pairing for that one: signal only the direct child, as the first
  # version of this watchdog did. It still ANSWERS 124 -- the marker says the
  # bound was reached -- while the grandchild runs to completion, so only the
  # wall clock tells the two apart. That is why this case asserts a duration.
  gklib="tests/fuzz/.probe_gklib$$.sh"
  cp "$tlib" "$gklib"
  sed -i.bak 's@kill -TERM "-\$cmd_pid" 2>/dev/null || @@; s@kill -KILL "-\$cmd_pid" 2>/dev/null || @@' "$gklib" && rm -f "$gklib.bak"
  if grep -q 'kill -TERM "-\$cmd_pid"' "$gklib"; then
    bad "the group-kill mutation did not apply -- the grandchild case is unattributed"
  else
    gkline="$(bash "$wdcase" "$ROOT/$gklib" grandchild 2>&1 | tail -1)"
    gkel="${gkline##*elapsed=}"
    case "$gkel" in
      ''|*[!0-9]*) bad "pre-fix group-kill: unreadable result '$gkline'" ;;
      *)
        if [ "$gkel" -ge 10 ]; then
          say "  ok   pre-fix: signalling only the direct child ran ${gkel}s -- the bound did not bind"
        else
          bad "pre-fix: the direct-child-only kill also finished in ${gkel}s -- the case above proves nothing"
        fi
        ;;
    esac
  fi
  rm -f "$gklib"
  rm -rf "$FIND"
  out="$(bash "$tprobe" --seeds 1..2 --jobs 1 --cli "$STAGE2" 2>&1)"; trc=$?
  case "$out" in
    *"[fuzz] mode="*) say "  ok   a campaign runs on the fallback" ;;
    *) bad "no campaign announced on the fallback: $(printf '%s' "$out" | tail -1)" ;;
  esac
  case "$out" in
    *", 0 findings"*) say "  ok   and reports 0 findings, not one per seed" ;;
    *) bad "the fallback campaign did not come back clean: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$trc" -eq 0 ] && say "  ok   exits 0" || bad "the fallback campaign exited $trc"
  # A watchdog that cannot bound a command has no verdict for that seed, and
  # that must reach the CAMPAIGN. It did not: `compile` and `classify` are
  # called as `st=$(...)`, so the `exit 125` inside them ended only the
  # command substitution -- measured, `seed_1_` with an empty class and
  # `2 seeds, 2 findings`, compiler bugs fabricated by a broken watchdog
  # (#2955 review). The status is propagated to run_seed now, which ends the
  # seed without a completion stamp, so the count refuses the campaign.
  nomark="tests/fuzz/.probe_nomarklib$$.sh"
  nomarkrun="tests/fuzz/.probe_nomarkrun$$.sh"
  cp "$tlib" "$nomark"
  cp "$tprobe" "$nomarkrun"
  sed -i.bak "s@$(basename "$tlib")\"@$(basename "$nomark")\"@" "$nomarkrun" && rm -f "$nomarkrun.bak"
  sed -i.bak 's@^  marker="\$(mktemp .*$@  marker=""@' "$nomark" && rm -f "$nomark.bak"
  if grep -q '^  marker=""$' "$nomark"; then
    say "  ok   mutant staged: the marker cannot be allocated mid-campaign"
    rm -rf "$FIND"
    out="$(bash "$nomarkrun" --seeds 1..2 --jobs 1 --cli "$STAGE2" 2>&1)"; nrc=$?
    case "$out" in
      *"refusing to report a campaign that did not run"*) say "  ok   the campaign refuses" ;;
      *) bad "the campaign did not refuse: $(printf '%s' "$out" | tail -1)" ;;
    esac
    case "$out" in
      *"findings"*[0-9]*"findings"*|*", 2 findings"*) bad "it reported findings: $(printf '%s' "$out" | tail -1)" ;;
      *) say "  ok   and reports no findings at all" ;;
    esac
    [ "$nrc" -ne 0 ] && say "  ok   nonzero exit ($nrc)" || bad "exited 0 with no verdict for any seed"
    if [ -d "$FIND" ] && [ -n "$(ls -A "$FIND" 2>/dev/null)" ]; then
      bad "a finding was recorded from a broken watchdog: $(ls -A "$FIND" | head -1)"
    else
      say "  ok   nothing was written to findings/"
    fi
    # Paired: same mutant, propagation removed. It must fabricate the
    # empty-class findings that were measured before the fix.
    sed -i.bak 's@ || watchdog_failed "\$seed" \$?@@g' "$nomarkrun" && rm -f "$nomarkrun.bak"
    if grep -q 'watchdog_failed "\$seed"' "$nomarkrun"; then
      bad "the propagation mutation did not apply -- the case above is unattributed"
    else
      rm -rf "$FIND"
      out="$(bash "$nomarkrun" --seeds 1..2 --jobs 1 --cli "$STAGE2" 2>&1)"
      case "$out" in
        *", 2 findings"*) say "  ok   pre-fix: '$(printf '%s' "$out" | tail -1)' -- fabricated from a broken watchdog" ;;
        *) bad "pre-fix: no fabricated findings ($(printf '%s' "$out" | tail -1)) -- the case above proves nothing" ;;
      esac
    fi
    rm -rf "$FIND"
  else
    bad "the marker mutation did not apply -- this case would prove nothing"
  fi
  rm -f "$nomark" "$nomarkrun"

  # The fallback's marker allocation is part of selecting it: a marker it
  # cannot allocate is not a smaller answer but a wrong one -- the watchdog
  # would still kill at the deadline and report the signal status, so a
  # compiler hang would be recorded as COMPILE_CRASH (#2955 review). With no
  # usable TMPDIR the run must refuse, and refuse BEFORE the reset and the
  # banner.
  rm -rf "$FIND"; mkdir -p "$FIND/seed_9_REAL_EVIDENCE"
  printf 'repro\n' > "$FIND/seed_9_REAL_EVIDENCE/single.vibe"
  out="$(TMPDIR="/nonexistent-tmp-$$" bash "$tprobe" --seeds 1..1 --jobs 1 --cli "$STAGE2" 2>&1)"; mrc=$?
  case "$out" in
    *"TMPDIR"*) say "  ok   an unusable TMPDIR is refused, naming what to set" ;;
    *) bad "no TMPDIR refusal: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$mrc" -ne 0 ] && say "  ok   nonzero exit ($mrc)" || bad "exited 0 with no marker directory"
  case "$out" in
    *"[fuzz] mode="*) bad "the run ANNOUNCED itself and fuzzed anyway" ;;
    *) say "  ok   no campaign was started" ;;
  esac
  if [ -f "$FIND/seed_9_REAL_EVIDENCE/single.vibe" ]; then
    say "  ok   and that refusal landed before the reset too"
  else
    bad "the TMPDIR refusal DESTROYED the previous findings"
  fi
  rm -rf "$FIND"
else
  bad "the timeout probe was not staged -- this case would prove nothing"
fi

# The pairing: the unconditional call this replaced, with the binary absent.
# It must reach the silently-wrong outcome -- a campaign that announces itself
# and reports a finding for every seed.
sed -i.bak '/^if command -v vibe_absent_timeout /,/^fi$/d' "$tlib" && rm -f "$tlib.bak"
sed -i.bak 's@^  run_bounded "\$CTIMEOUT"@  vibe_absent_timeout "$CTIMEOUT"@' "$tlib" && rm -f "$tlib.bak"
sed -i.bak 's@out=\$(run_bounded "\$RTIMEOUT"@out=$(vibe_absent_timeout "$RTIMEOUT"@' "$tlib" && rm -f "$tlib.bak"
if ! grep -q 'TIMEOUT_BIN=' "$tlib" && grep -q 'vibe_absent_timeout "\$CTIMEOUT"' "$tlib"; then
  say "  ok   pre-fix mutant staged: the timeout command is called unconditionally"
  rm -rf "$FIND"
  out="$(bash "$tprobe" --seeds 1..2 --jobs 1 --cli "$STAGE2" 2>&1)"
  case "$out" in
    *"[fuzz] mode="*) say "  ok   pre-fix: it announces a campaign" ;;
    *) bad "pre-fix: no campaign announced: $(printf '%s' "$out" | tail -1)" ;;
  esac
  case "$out" in
    *", 0 findings"*) bad "pre-fix: it reported 0 findings -- the case above proves nothing" ;;
    *"findings"*) say "  ok   pre-fix: and reports a finding per seed -- $(printf '%s' "$out" | tail -1)" ;;
    *) bad "pre-fix: the campaign did not complete: $(printf '%s' "$out" | tail -1)" ;;
  esac
else
  bad "the pre-fix timeout mutation did not apply -- the case above is unattributed"
fi
rm -f "$tprobe" "$tlib" "$wdcase" "$gklib"
rm -rf "$FIND"

say "=== red: a malformed or zero-padded range must not touch the findings ==="
# Two shapes, one property: nothing destructive happens before the range is
# known good. `typo` has no `..`; `08..09` is digit-only and passes `[ -le ]`
# but is an invalid octal literal to `$(( ))`, so it used to clear both
# records and then die at `total=$((B - A + 1))` (#2955 review).
# 18446744073709551616 overflows bash's signed integer: `$((10#...))` wrapped
# it to 0, so the harness cleared the findings and ran seed 0 under a range
# nobody asked for. Endpoints are bounded by digit count before any arithmetic
# now (#2955 review).
# The check is TOTAL -- the input must be exactly its own two endpoints
# rejoined -- so this list is a sample of a closed property, not the property
# itself. `1..oops..2` is the shape that motivated it: `%%..*` and `##*..`
# extracted 1 and 2, an enumerated `*..*` test saw nothing wrong, and the
# harness measured a range nobody asked for (#2955 review).
for rng in typo 9..1 18446744073709551616..18446744073709551616 1..oops..2 1...2 1..2..3..4 ..5 5..; do
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

say "=== red: a campaign that did not run must not report a clean sweep ==="
# `[fuzz] done: 750 seeds, 0 findings` is what gets pasted into an issue as
# acceptance evidence, and it was arithmetic on the endpoints -- `total=$((B -
# A + 1))` -- not a count of anything that happened. Measured with `seq` made
# unresolvable (it is not POSIX): the loop produced nothing, and the harness
# printed exactly that line, exit 0, in under a second, having compiled
# nothing (#2955 review).
#
# Two fixes, and the second is the one that closes the shape: the loop is
# shell arithmetic so there is no external command to lose, AND the total is
# counted from per-seed completion stamps, so whatever else empties the loop,
# the campaign says so instead of reporting a sweep.
if grep -qE '(^|[^_a-zA-Z])seq ' tests/fuzz/run_fuzz.sh; then
  bad "run_fuzz.sh calls seq again -- the seed loop must not need a non-POSIX command"
else
  say "  ok   the seed loop needs no external command"
fi

seedcase() { # <name> <sed-expr>... -> path
  local nm="$1"
  shift
  local dst="tests/fuzz/.probe_seed${nm}$$.sh"
  cp tests/fuzz/run_fuzz.sh "$dst"
  while [ $# -gt 0 ]; do
    sed -i.bak "$1" "$dst" && rm -f "$dst.bak"
    shift
  done
  printf '%s\n' "$dst"
}

# (a) nothing iterates at all.
empty="$(seedcase empty 's@^while \[ "\$seed" -le "\$B" \]; do$@while false; do@')"
if grep -q '^while false; do' "$empty"; then
  say "  ok   mutant staged: the seed loop iterates nothing"
  out="$(bash "$empty" --seeds 1..750 --jobs 4 --cli "$STAGE2" 2>&1)"; erc=$?
  case "$out" in
    *"refusing to report a campaign that did not run"*) say "  ok   it refuses instead of summarising" ;;
    *) bad "no refusal for an empty campaign: $(printf '%s' "$out" | tail -1)" ;;
  esac
  case "$out" in
    *"0 findings"*) bad "it still printed a findings summary: $(printf '%s' "$out" | tail -1)" ;;
    *) say "  ok   and prints no findings summary at all" ;;
  esac
  [ "$erc" -ne 0 ] && say "  ok   nonzero exit ($erc)" || bad "exited 0 having run no seeds"
else
  bad "the empty-loop mutation did not apply -- this case would prove nothing"
fi
rm -f "$empty"

# The pairing: same empty loop, count check removed. This is the pre-fix
# harness, and it must produce the silently-wrong line verbatim.
empty_drop="$(seedcase emptydrop 's@^while \[ "\$seed" -le "\$B" \]; do$@while false; do@' 's@^if \[ "\$ran" -ne "\$total" \]; then$@if false; then@' 's@^echo "\[fuzz\] done: \$ran seeds, \$fail findings"$@echo "[fuzz] done: $total seeds, $fail findings"@')"
if grep -q '^if false; then' "$empty_drop" && grep -q 'done: \$total seeds' "$empty_drop"; then
  say "  ok   control staged: endpoint arithmetic, no count check"
  out="$(bash "$empty_drop" --seeds 1..750 --jobs 4 --cli "$STAGE2" 2>&1)"; crc=$?
  case "$out" in
    *"done: 750 seeds, 0 findings"*) say "  ok   pre-fix: '$(printf '%s' "$out" | tail -1)' -- a clean sweep of nothing" ;;
    *) bad "control did not reproduce the summary: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$crc" -eq 0 ] && say "  ok   control exits 0, so the refusal above is the count check's doing" || bad "control exited $crc"
else
  bad "the control mutation did not apply -- the case above is unattributed"
fi
rm -f "$empty_drop"

# (b) the subtler half: the loop runs, but one seed's process never finishes
# (killed, OOM). The endpoint total cannot see it; a count can.
lost="$(seedcase lost 's@^  printf .%s\\n. "\$RUN_ID" > "\$dir/.seed_done"$@  [ "$seed" = "2" ] || printf "%s\\n" "$RUN_ID" > "$dir/.seed_done"@')"
if grep -q '\[ "\$seed" = "2" \] ||' "$lost"; then
  say "  ok   mutant staged: seed 2 never completes"
  out="$(bash "$lost" --seeds 1..3 --jobs 2 --cli "$STAGE2" 2>&1)"; lrc=$?
  case "$out" in
    *"only 2 of 3 seeds ran"*) say "  ok   the refusal names how many ran, and which is missing" ;;
    *) bad "a lost seed was not noticed: $(printf '%s' "$out" | tail -1)" ;;
  esac
  [ "$lrc" -ne 0 ] && say "  ok   nonzero exit ($lrc)" || bad "exited 0 with a seed unaccounted for"
else
  bad "the lost-seed mutation did not apply -- this case would prove nothing"
fi
rm -f "$lost"

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
sed -i.bak '/^# >>> findings reset$/,/^# <<< findings reset$/d' "$probe" && rm -f "$probe.bak"
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
