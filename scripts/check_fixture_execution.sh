#!/usr/bin/env bash
# Fixture execution coverage check (#1587).
#
# THE INVARIANT: a fixture that carries `test` blocks either runs somewhere, or
# is listed with a reason. There is no third state.
#
# The third state is what this exists to kill. Gates used to enumerate their
# test-block fixtures by hand (`for fx in \` + a backslash-continued list), so
# committing a fixture and forgetting the gate edit left a file that looks like
# coverage, is named like coverage, and is executed by nothing. Nobody notices,
# because nothing fails -- the same "silently wrong" shape as #1631, one level
# up. Two live instances when this check was written:
#
#   - the #641 Phase 1 acceptance fixture (method-bearing trait syntax with
#     concrete-receiver dispatch) -- two `test` blocks, referenced by no
#     script, run by no lane, since 2026-06.
#   - the nine fixtures/runtime/ struct fixtures -- test blocks sitting AFTER a
#     stray `__DATA__` marker, so they were not even source. Compiling one
#     gives `line 13:1: top-level expressions are not allowed`; they had been
#     uncompilable, and unnoticed, for as long as they existed.
#
# (Both are named `*_test.vibe` now and run in the unit lane. This header names
# no fixture by filename on purpose: route 3 below is a plain name grep over
# scripts/, so a filename written here would account for that fixture forever,
# and this file would quietly become the thing keeping it "covered".)
#
# A test-block fixture is accounted for when ANY of these holds:
#
#   1. scripts/unit_test_runner.sh --list contains it. That runner globs
#      `*_test.vibe` under examples/ lib/ fixtures/ and subtracts a documented
#      EXCLUDE_PATTERNS list -- it is the glob-plus-exceptions shape this check
#      generalizes, and following the `*_test.vibe` convention is the cheapest
#      way to be covered.
#   2. It lives in fixtures/typecheck/ and has a row in expected.tsv. That lane
#      is manifest-driven by necessity (each row carries an expected VERDICT --
#      ok / reject / debt-*; a glob cannot supply that), so the invariant there
#      is exhaustiveness, checked separately below.
#   3. Some file under scripts/ lib/ examples/ .github/ names it. That is a
#      bespoke check -- a gate asserting one specific value or diagnostic, or a
#      vibe test driving the fixture as data.
#   4. scripts/fixture_execution_exceptions.txt lists it, with a reason.
#
# Route 3 is a name reference, not proof of execution: a fixture mentioned only
# in a comment passes. That is deliberate. This check makes the silent state
# visible, it does not verify that every reference runs -- widening it to
# "referenced from an executed command" would need to parse shell, and the
# failure it would catch (a fixture whose gate section was deleted but whose
# comment survived) is loud in review, unlike the one it does catch.
#
# Usage:
#   bash scripts/check_fixture_execution.sh          # exit 1 on any violation
#   bash scripts/check_fixture_execution.sh --list   # print the accounted set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

EXCEPTIONS_FILE="scripts/fixture_execution_exceptions.txt"
TYPECHECK_TSV="fixtures/typecheck/expected.tsv"

mode="check"
case "${1:-}" in
  --list) mode="list" ;;
  "") ;;
  *) echo "unknown argument: $1 (expected --list)" >&2; exit 2 ;;
esac

# A `test` block opens as `test {`, `test "name" {`, or -- since #1508 -- with
# an effect row: `test with Row {` / `test "name" with Row {`. Matching the
# keyword plus one of those three continuations keeps identifiers that merely
# start with "test" (`test_helper = ...`) out of the set.
TEST_BLOCK_RE='^[[:space:]]*test([[:space:]]+"|[[:space:]]*\{|[[:space:]]+with[[:space:]])'

# --- the accounted-for sets -------------------------------------------------
unit_list="$(bash scripts/unit_test_runner.sh --list)"

exceptions=""
if [ -f "$EXCEPTIONS_FILE" ]; then
  exceptions="$(grep -v '^[[:space:]]*#' "$EXCEPTIONS_FILE" | grep -v '^[[:space:]]*$' || true)"
fi

typecheck_rows=""
if [ -f "$TYPECHECK_TSV" ]; then
  typecheck_rows="$(grep -v '^#' "$TYPECHECK_TSV" | cut -f1 || true)"
fi

in_set() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

violations=0
accounted=0

# --- 1. every test-block fixture is executed somewhere -----------------------
while IFS= read -r f; do
  grep -qE "$TEST_BLOCK_RE" "$f" || continue

  if in_set "$f" "$unit_list"; then
    [ "$mode" = "list" ] && printf '%s\tunit-test-runner\n' "$f"
    accounted=$((accounted + 1)); continue
  fi

  case "$f" in
    fixtures/typecheck/*)
      if in_set "$(basename "${f%.vibe}")" "$typecheck_rows"; then
        [ "$mode" = "list" ] && printf '%s\ttypecheck-expected-tsv\n' "$f"
        accounted=$((accounted + 1)); continue
      fi
      ;;
  esac

  # --exclude: neither this script nor the exceptions manifest may account for
  # a fixture by merely mentioning it.
  #
  # This script, because the header note names the shapes it was built for and
  # a filename written there would cover that fixture forever.
  #
  # The manifest, because its entries are prose plus a path: comment out or
  # delete an entry and the basename survives in the reason text above it, so
  # a withdrawn exception would silently become a "bespoke reference" and the
  # fixture would go on being executed by nothing -- the exact state this
  # check exists to make impossible. An exception must count through the
  # explicit lookup below or not at all.
  if grep -rqF --exclude="$(basename "${BASH_SOURCE[0]}")" \
      --exclude="$(basename "$EXCEPTIONS_FILE")" \
      -- "$(basename "$f")" scripts lib examples .github 2>/dev/null; then
    [ "$mode" = "list" ] && printf '%s\tbespoke-reference\n' "$f"
    accounted=$((accounted + 1)); continue
  fi

  if in_set "$f" "$exceptions"; then
    [ "$mode" = "list" ] && printf '%s\texception\n' "$f"
    accounted=$((accounted + 1)); continue
  fi

  if [ "$mode" != "list" ]; then
    echo "[fixture-execution] FAIL: $f has test blocks but no lane runs it" >&2
    echo "                    fix by ONE of:" >&2
    echo "                      - rename it to *_test.vibe (scripts/unit_test_runner.sh globs those)" >&2
    echo "                      - add a gate check that names it" >&2
    echo "                      - add it to $EXCEPTIONS_FILE with the reason" >&2
  fi
  violations=$((violations + 1))
done < <(find fixtures -name '*.vibe' | sort)

# --- 2. fixtures/typecheck/ is exhaustively classified -----------------------
# The verdict table is the lane, so a fixture missing from it is unchecked even
# when it has no test block (most of these are single-declaration accept/reject
# cases). This is the union check: rows + exceptions must cover the directory.
if [ -f "$TYPECHECK_TSV" ]; then
  while IFS= read -r f; do
    in_set "$(basename "${f%.vibe}")" "$typecheck_rows" && continue
    in_set "$f" "$exceptions" && continue
    if [ "$mode" != "list" ]; then
      echo "[fixture-execution] FAIL: $f has no verdict row in $TYPECHECK_TSV" >&2
      echo "                    add a row (ok / reject / debt-accepts / debt-rejects)," >&2
      echo "                    or list it in $EXCEPTIONS_FILE if it is not a case" >&2
    fi
    violations=$((violations + 1))
  done < <(find fixtures/typecheck -maxdepth 1 -name '*.vibe' | sort)
fi

# --- 3. no stale exception entries -------------------------------------------
# An exception for a file that no longer exists is a lie the next reader has to
# disprove; drop it when the fixture goes.
if [ -n "$exceptions" ]; then
  while IFS= read -r e; do
    [ -f "$e" ] && continue
    if [ "$mode" != "list" ]; then
      echo "[fixture-execution] FAIL: $EXCEPTIONS_FILE lists '$e', which does not exist" >&2
    fi
    violations=$((violations + 1))
  done <<< "$exceptions"
fi

[ "$mode" = "list" ] && exit 0

if [ "$violations" -gt 0 ]; then
  echo "[fixture-execution] $violations violation(s)" >&2
  exit 1
fi
echo "[fixture-execution] ok ($accounted test-block fixtures, all accounted for)"
