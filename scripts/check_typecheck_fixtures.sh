#!/usr/bin/env bash
# fixtures/typecheck verdicts, asked in BOTH lanes (#138, #2142, #2144).
#
# The corpus used to be compiled one way only: entry `__no_entry__`, which
# builds a test runner and never lowers an entry boundary. A `handle` whose
# eligibility is judged in that lowering (ADR-0076) is therefore never judged
# for a fixture whose only code is `fn main`, and the row records `ok` for a
# program `vibe check` rejects. Both verdicts are correct for what they ran;
# the row is what is wrong, because it reads as a claim about the language.
#
# So every row is now compiled twice -- once with `__no_entry__`, once with the
# entry name a user would pass, `main` -- and the two verdicts are compared:
#
#   * A fixture that declares no `main` has no entry lane. The compile fails on
#     the entry name itself, and the row is checked in the no-entry lane only.
#     (This is why the corpus cannot simply switch entry names wholesale: most
#     rows are declaration-only, and "entry not found" would count as
#     "rejected" with the check under test never having run.)
#   * A fixture that does declare `main` must produce the SAME verdict in both
#     lanes, unless its row records the difference in columns 4-5. An
#     unrecorded difference FAILS -- that is the thing that used to be
#     invisible.
#
# Columns (tab separated):
#
#   1 name          fixture stem, in fixtures/typecheck/ or fixtures/
#   2 status        ok | reject | debt-accepts | debt-rejects  (no-entry lane)
#   3 needle        substring of the diagnostic, for a rejecting row
#   4 entry-status  ok | reject -- ONLY when the entry lane disagrees with 2
#   5 entry-needle  substring of the entry lane's diagnostic, when 4 is reject
#   6 entry-output  exact stdout from invoking a successful `main` artifact
#
# Columns 4-5 are the record of a divergence, so a row that names an entry
# verdict equal to its no-entry verdict is itself an error: the annotation has
# gone stale and would hide the next real one.
#
# Measured over all 233 rows both ways, on a stage2 built from this checkout:
# 204 agree, 28 have no `main` to name, and exactly 1 diverges
# (handle_callee_local_closure_arg). On the committed SEED the same run gives
# 33 with no `main` and the same single divergence -- the five rows that move
# are ones this checkout changed (#2125, #2152, import kinds), which is the
# reason the compiler is passed in rather than picked.
#
# Usage:
#   bash scripts/check_typecheck_fixtures.sh
#   TYPECHECK_FIXTURES_STAGE2=<path to stage2.wasm> bash scripts/check_typecheck_fixtures.sh
#   bash scripts/check_typecheck_fixtures.sh --selftest   # row-checker only, no compiler
#
# A gate must be told WHICH compiler (AGENTS.md, "Which compiler answered?").
# tests/gates/late/run.sh passes the stage2 it resolved; standalone runs fall
# back through scripts/resolve_stage2.sh, which says on stderr what it settled
# for.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mode="check"
case "${1:-}" in
  --selftest) mode="selftest" ;;
  "") ;;
  *) echo "unknown argument: $1 (expected --selftest)" >&2; exit 2 ;;
esac

TSV="fixtures/typecheck/expected.tsv"
WORK="_build/_gate_typecheck_fixtures"
# The substring that says "this fixture has no `main` to name" rather than
# "this program is rejected". Measured on a declaration-only fixture, whose
# entry-lane diagnostic reads in full:
#
#   entry `main` not found: no exported function named `main`
#   (use __no_entry__ to build a test runner)
#
# If that wording ever changes, every declaration-only row starts being read as
# a rejection and the counts printed at the end move -- which is why the count
# of rows with no entry lane is reported rather than left implicit.
ENTRY_MISSING_NEEDLE="entry \`main\` not found"
# Reserved for the self-test's synthetic rows; must never name a real fixture.
PROBE_PREFIX="__selftest_probe"

rm -rf "$WORK"
mkdir -p "$WORK/noentry" "$WORK/entry"

names="$(grep -v '^#' "$TSV" | cut -f1 | grep -v '^$' || true)"
if [ -z "$names" ]; then
  echo "[typecheck-fixtures] FAIL: $TSV has no rows" >&2
  exit 1
fi

fixture_src() { # <name>
  local src="fixtures/typecheck/$1.vibe"
  [ -f "$src" ] || src="fixtures/$1.vibe"
  printf '%s\n' "$src"
}

# One compile each, fanned out. A row names a fixture in fixtures/typecheck/,
# or -- for the #2125 orphans adopted from the repository root -- one directly
# under fixtures/. Resolving in that order avoids moving 139 files and keeps
# names unique (checked: the two directories share none).
compile_lane() { # <entry name> <outdir>
  printf '%s\n' $names | xargs -P "$(nproc 2>/dev/null || echo 4)" -n 1 env \
    ROOT_DIR="$ROOT_DIR" STAGE2="$STAGE2" entry="$1" outdir="$2" \
    bash -c 'name="$1"
      src="fixtures/typecheck/$name.vibe"; [ -f "$src" ] || src="fixtures/$name.vibe"
      VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
      "$src" "$outdir/$name.wasm" "$entry" >/dev/null 2>&1 || true' _
}

if [ "$mode" = "check" ]; then
  # shellcheck source=resolve_stage2.sh
  . "$ROOT_DIR/scripts/resolve_stage2.sh"
  STAGE2="$(resolve_stage2 typecheck-fixtures "${TYPECHECK_FIXTURES_STAGE2:-}")" || exit 1
  compile_lane __no_entry__ "$WORK/noentry"
  compile_lane main "$WORK/entry"
fi

verdict_of() { # <lane dir> <name>
  if [ -s "$WORK/$1/$2.wasm" ]; then printf 'ok\n'; else printf 'reject\n'; fi
}
diag_of() { # <lane dir> <name>
  head -1 "$WORK/$1/$2.wasm.diag" 2>/dev/null || true
}
want_of() { # <status>
  case "$1" in
    ok|debt-accepts) printf 'ok\n' ;;
    reject|debt-rejects) printf 'reject\n' ;;
    *) return 1 ;;
  esac
}

# check_row <name> <status> <needle> <entry-status> <entry-needle>
# Prints every violation it finds on stderr; returns 1 when it found any.
# Every assertion this gate makes lives here, so the self-test below can drive
# it directly with synthetic verdicts -- a gate that cannot be shown failing is
# not evidence that it can fail.
check_row() {
  local name="$1" status="$2" needle="$3" estatus="$4" eneedle="$5"
  local src want act diag ewant eact ediag rc=0
  src="$(fixture_src "$name")"
  if ! want="$(want_of "$status")"; then
    echo "[typecheck-fixtures] FAIL: unknown status '$status' for $name in $TSV" >&2
    return 1
  fi
  act="$(verdict_of noentry "$name")"
  diag="$(diag_of noentry "$name")"
  if [ "$act" != "$want" ]; then
    case "$status" in
      debt-accepts)
        echo "[typecheck-fixtures] FAIL: $src is REJECTED again -- the lost check is back. Promote its row in $TSV from 'debt-accepts' to 'reject' with the new message (#138)." >&2 ;;
      debt-rejects)
        echo "[typecheck-fixtures] FAIL: $src COMPILES again. Promote its row in $TSV from 'debt-rejects' to 'ok' (#138)." >&2 ;;
      *)
        echo "[typecheck-fixtures] FAIL: $src expected '$want', got '$act' in the no-entry lane (#138)" >&2 ;;
    esac
    if [ -n "$diag" ]; then echo "    diag: $diag" >&2; fi
    rc=1
  elif [ "$want" = "reject" ] && [ -n "$needle" ]; then
    case "$diag" in
      *"$needle"*) ;;
      *)
        echo "[typecheck-fixtures] FAIL: $src is rejected, but not for the recorded reason (#138)" >&2
        echo "    expected substring: $needle" >&2
        echo "    actual:             $diag" >&2
        rc=1 ;;
    esac
  fi

  # --- the entry lane (#2142, #2144) ---
  eact="$(verdict_of entry "$name")"
  ediag="$(diag_of entry "$name")"
  case "$ediag" in
    *"$ENTRY_MISSING_NEEDLE"*)
      # No `main` to name: this fixture has no entry lane at all.
      if [ -n "$estatus" ]; then
        echo "[typecheck-fixtures] FAIL: $src has no \`main\`, so it has no entry lane, but its row records one ('$estatus'). Drop columns 4-5 (#2142)." >&2
        rc=1
      fi
      return "$rc" ;;
  esac
  if [ -n "$estatus" ]; then
    if ! ewant="$(want_of "$estatus")"; then
      echo "[typecheck-fixtures] FAIL: unknown entry-lane status '$estatus' for $name in $TSV (expected 'ok' or 'reject')" >&2
      return 1
    fi
    if [ "$ewant" = "$want" ]; then
      echo "[typecheck-fixtures] FAIL: $src records an entry-lane verdict ('$estatus') equal to its no-entry verdict ('$status'). Columns 4-5 record a DIVERGENCE; a stale one hides the next real one -- drop them (#2142)." >&2
      rc=1
    fi
  else
    # No annotation: the two LANES must agree. Compare against what the
    # no-entry lane actually did, not against what the row wanted -- a row
    # whose column-2 verdict has already failed above would otherwise get a
    # second, contradictory report ("differently in the two lanes: 'ok' ...
    # 'ok'") on top of the real one.
    ewant="$act"
  fi
  if [ "$eact" != "$ewant" ]; then
    if [ -n "$estatus" ]; then
      echo "[typecheck-fixtures] FAIL: $src no longer diverges as recorded: entry \`main\` gives '$eact', its row says '$estatus' (#2142)." >&2
    else
      echo "[typecheck-fixtures] FAIL: $src answers differently in the two lanes: '$act' with \`__no_entry__\`, '$eact' with entry \`main\`. A user runs the second one." >&2
      echo "    Either fix the fixture, or record the divergence in $TSV columns 4-5 (entry-status, entry-needle) with a comment saying why (#2142, #2144)." >&2
    fi
    if [ -n "$ediag" ]; then echo "    entry-lane diag: $ediag" >&2; fi
    rc=1
  elif [ "$ewant" = "reject" ] && [ -n "$eneedle" ]; then
    case "$ediag" in
      *"$eneedle"*) ;;
      *)
        echo "[typecheck-fixtures] FAIL: $src is rejected with entry \`main\`, but not for the recorded reason (#2142)" >&2
        echo "    expected substring: $eneedle" >&2
        echo "    actual:             $ediag" >&2
        rc=1 ;;
    esac
  fi
  return "$rc"
}

# --- self-test: the checker must be able to FAIL -------------------------
# Red before green, with no compiler involved: synthetic lane artifacts drive
# check_row directly. A checker that has never been shown rejecting something
# is not evidence about anything, and this one exists precisely because the
# state it rejects went unnoticed for a whole corpus.
#
# Each RED case was confirmed by mutation: disabling the entry-lane comparison,
# the entry-needle check, the stale-annotation check, or the no-entry-lane
# detection each turns exactly one of them red. Case 4 needs BOTH lanes
# rejecting -- with an `ok` row the ordinary verdict comparison catches it
# anyway, and the probe proves nothing about the check it is aimed at.
selftest() {
  local ok=0
  probe() { # <case> <noentry verdict> <entry verdict> <entry diag>
    local case_name="${PROBE_PREFIX}_$1"
    rm -f "$WORK/noentry/$case_name.wasm" "$WORK/entry/$case_name.wasm"
    : > "$WORK/noentry/$case_name.wasm.diag"
    if [ "$2" = "ok" ]; then printf 'x' > "$WORK/noentry/$case_name.wasm"; fi
    if [ "$3" = "ok" ]; then printf 'x' > "$WORK/entry/$case_name.wasm"; fi
    printf '%s\n' "$4" > "$WORK/entry/$case_name.wasm.diag"
    printf '%s\n' "$case_name"
  }
  local p probe_out
  # 1. RED: the divergence this gate exists for, with no annotation.
  p="$(probe diverges ok reject "some rejection")"
  if check_row "$p" ok "" "" "" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: an unrecorded lane divergence was accepted" >&2
    ok=1
  fi
  # 2. GREEN: the same divergence, recorded.
  p="$(probe recorded ok reject "some rejection")"
  if ! check_row "$p" ok "" reject "some rejection" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: a recorded divergence was rejected" >&2
    ok=1
  fi
  # 3. RED: recorded with the wrong reason.
  p="$(probe wrong_needle ok reject "some rejection")"
  if check_row "$p" ok "" reject "a different reason" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: a divergence recorded with the wrong needle was accepted" >&2
    ok=1
  fi
  # 4. RED: an annotation that no longer diverges -- both lanes now reject, so
  #    nothing else in check_row would notice that columns 4-5 are dead weight.
  p="$(probe stale reject reject "some rejection")"
  if check_row "$p" reject "" reject "some rejection" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: a stale entry-lane annotation was accepted" >&2
    ok=1
  fi
  # 5. RED: an annotation on a fixture that has no entry lane.
  p="$(probe no_entry_lane ok reject "$ENTRY_MISSING_NEEDLE")"
  if check_row "$p" ok "" reject "whatever" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: an entry-lane annotation on a fixture with no \`main\` was accepted" >&2
    ok=1
  fi
  # 6. GREEN: agreeing lanes, no annotation -- the ordinary row.
  p="$(probe agrees ok ok "")"
  if ! check_row "$p" ok "" "" "" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: an ordinary agreeing row was rejected" >&2
    ok=1
  fi
  # 7. RED, but only ONCE: the no-entry verdict itself is wrong and the lanes
  #    agree. The row must fail on column 2 and NOT also be reported as a lane
  #    divergence -- that report would read "'reject' ... 'reject'".
  p="$(probe wrong_verdict reject reject "some rejection")"
  probe_out="$(check_row "$p" ok "" "" "" 2>&1 || true)"
  case "$probe_out" in
    *"answers differently in the two lanes"*)
      echo "[typecheck-fixtures] FAIL: self-test: a row that merely has the wrong column-2 verdict was also reported as a lane divergence" >&2
      ok=1 ;;
  esac
  case "$probe_out" in
    *"expected 'ok', got 'reject'"*) ;;
    *)
      echo "[typecheck-fixtures] FAIL: self-test: a wrong column-2 verdict was not reported" >&2
      ok=1 ;;
  esac
  # 8. GREEN: no `main`, no annotation -- the 28 rows with no entry lane.
  p="$(probe declaration_only ok reject "$ENTRY_MISSING_NEEDLE")"
  if ! check_row "$p" ok "" "" "" 2>/dev/null; then
    echo "[typecheck-fixtures] FAIL: self-test: a declaration-only row was rejected" >&2
    ok=1
  fi
  rm -f "$WORK"/noentry/"$PROBE_PREFIX"* "$WORK"/entry/"$PROBE_PREFIX"*
  return "$ok"
}

# Split one row into ROW[0..5]. NOT `IFS=$'\t' read`: a tab is IFS
# whitespace, so bash collapses a run of them and `name<TAB>ok<TAB><TAB>reject`
# hands `reject` to the NEEDLE field. That is invisible until a row has an
# empty column 3 -- which the first recorded divergence has.
split_row() { # <line>
  local line="$1" i=0 f
  ROW=("" "" "" "" "" "")
  while [ "$i" -lt 6 ]; do
    case "$line" in
      *$'\t'*) f="${line%%$'\t'*}"; line="${line#*$'\t'}" ;;
      *) f="$line"; line="" ;;
    esac
    ROW[$i]="$f"
    i=$((i + 1))
  done
}

fail=0
selftest || fail=1
if [ "$mode" = "selftest" ]; then
  rm -rf "$WORK"
  if [ "$fail" -ne 0 ]; then exit 1; fi
  echo "[typecheck-fixtures] self-test ok (row-checker only; no compiler involved)"
  exit 0
fi

rows=0
debt=0
entry_rows=0
noentry_only=0
divergences=0
while IFS= read -r line; do
  split_row "$line"
  name="${ROW[0]}"; status="${ROW[1]}"; needle="${ROW[2]}"
  estatus="${ROW[3]}"; eneedle="${ROW[4]}"
  entry_output="${ROW[5]}"
  case "$name" in ''|'#'*) continue ;; esac
  case "$name" in "$PROBE_PREFIX"*)
    echo "[typecheck-fixtures] FAIL: '$name' collides with the self-test's reserved prefix" >&2
    fail=1; continue ;;
  esac
  rows=$((rows + 1))
  case "$status" in debt-accepts|debt-rejects) debt=$((debt + 1)) ;; esac
  case "$(diag_of entry "$name")" in
    *"$ENTRY_MISSING_NEEDLE"*) noentry_only=$((noentry_only + 1)) ;;
    *) entry_rows=$((entry_rows + 1)) ;;
  esac
  if [ -n "$estatus" ]; then divergences=$((divergences + 1)); fi
  check_row "$name" "$status" "$needle" "$estatus" "$eneedle" || fail=1
  if [ -n "$entry_output" ]; then
    artifact="$WORK/entry/$name.wasm"
    if [ ! -s "$artifact" ]; then
      echo "[typecheck-fixtures] FAIL: $name records entry output but has no runnable main artifact" >&2
      fail=1
    else
      actual_output="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$artifact" 2>&1 || true)"
      if [ "$actual_output" != "$entry_output" ]; then
        echo "[typecheck-fixtures] FAIL: $name main output '$actual_output' (want '$entry_output')" >&2
        fail=1
      fi
    fi
  fi
done < "$TSV"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
rm -rf "$WORK"
echo "[typecheck-fixtures] ok ($rows rows, $debt known debt; $entry_rows compared in both lanes, $noentry_only with no \`main\` to name, recorded divergences: $divergences)"
