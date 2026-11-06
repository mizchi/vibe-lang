#!/usr/bin/env bash
# #3718: `vibe rc-validate` over the RC fixture corpus. Each fixtures/rc_*.vibe
# file's Perceus plans are checked against the linear ownership discipline by
# the public verb. A plan that releases a reference it does not hold -- an
# over-release, a borrowed parameter consumed without a dup, or a consume mark
# on an occurrence that does not consume -- fails the gate: those are
# use-after-free shapes. A leak line is the safe direction the planner accepts
# today (#705), so it is counted and printed, not failed. A verb that errors
# fails too: an unanswered file would read exactly like a clean one.
#
# The corpus is a GLOB: a fixture joins by being named fixtures/rc_*.vibe.
#
# Usage:
#   bash scripts/check_rc_validate_corpus.sh
#   RC_VALIDATE_CORPUS_STAGE2=<stage2.wasm> bash scripts/check_rc_validate_corpus.sh
#   bash scripts/check_rc_validate_corpus.sh --mutate drop-dups   # self-test only
#
# `--mutate drop-dups` is passed to every verb call. It validates each plan
# with its dup rows deleted, which only scripts/check_rc_validate_corpus_test.sh
# uses: it is how the self-test shows a wrong plan in a real fixture fails
# this gate.
set -euo pipefail
# Overridable ONLY so this gate's own self-test can run a MUTATED COPY of this
# script from a scratch directory. Unset on every real invocation.
ROOT_DIR="${VIBE_RC_VALIDATE_CORPUS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

mutate=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mutate) [ "$#" -ge 2 ] || { echo "[rc-validate-corpus] FAIL: --mutate needs a value" >&2; exit 2; }
      mutate="$2"; shift 2 ;;
    *) echo "[rc-validate-corpus] FAIL: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A gate must be told WHICH compiler (CLAUDE.md, "Which compiler answered?").
# shellcheck source=resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 rc-validate-corpus "${RC_VALIDATE_CORPUS_STAGE2:-}")" || exit 1

# Overridable so the self-test can point the gate at a scratch corpus instead
# of editing the tree's own fixtures.
FIXTURE_GLOB="${RC_VALIDATE_CORPUS_FIXTURES:-fixtures/rc_*.vibe}"

# The failing line forms, named once.
fatal_pattern=': (owned value released [0-9]+ more than held|borrowed parameter consumed without a dup|consume mark at offset -?[0-9]+ is not a consuming occurrence)$'

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_rc_validate_corpus.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

files=0
leaks=0
skips=0
for src in $FIXTURE_GLOB; do
  [ -f "$src" ] || continue
  files=$((files + 1))
  status=0
  if [ -n "$mutate" ]; then
    VIBE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" VIBE_CLI_WASM="$STAGE2" \
      VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" rc-validate --mutate "$mutate" "$src" \
      > "$WORK/out.txt" 2> "$WORK/err.txt" || status=$?
  else
    VIBE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" VIBE_CLI_WASM="$STAGE2" \
      VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" rc-validate "$src" \
      > "$WORK/out.txt" 2> "$WORK/err.txt" || status=$?
  fi
  if [ "$status" != 0 ]; then
    echo "[rc-validate-corpus] FAIL: vibe rc-validate $src exited $status -- an unanswered file is not a clean one" >&2
    cat "$WORK/err.txt" "$WORK/out.txt" >&2
    exit 1
  fi
  if grep -qE "$fatal_pattern" "$WORK/out.txt"; then
    echo "[rc-validate-corpus] FAIL: vibe rc-validate $src found a plan that releases more than it holds:" >&2
    grep -E "$fatal_pattern" "$WORK/out.txt" >&2
    exit 1
  fi
  leaks=$((leaks + $(grep -c ': owned value not consumed' "$WORK/out.txt" || true)))
  skips=$((skips + $(grep -c ': not checked: ' "$WORK/out.txt" || true)))
done

if [ "$files" -eq 0 ]; then
  # Silence is "unchecked", not "clean".
  echo "[rc-validate-corpus] FAIL: no fixtures matched $FIXTURE_GLOB" >&2
  exit 1
fi

echo "[rc-validate-corpus] ok ($files files, $leaks leak lines, $skips not-checked lines)"
