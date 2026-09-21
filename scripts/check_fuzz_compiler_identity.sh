#!/usr/bin/env bash
# The fuzz harness is a MEASUREMENT, so it must not choose its own compiler.
#
# `tests/fuzz/run_fuzz.sh` used to default to
#
#     CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm | head -1)"
#
# -- newest by MTIME, which is a different question from "the compiler built
# from this checkout" (AGENTS.md, "Which compiler answered?"). Measured in a
# workspace where HEAD was 62bf997a9 and the previous candidate 6ebc33028 was
# still on disk, that default selected 6ebc33028: a re-run would have reported
# "0 findings" about the compiler the campaign had ALREADY measured, and the
# report says `cli=` with a path nobody reads twice.
#
# A campaign's result is pasted into an issue as a bare number with no stderr
# attached, so there is no honest fallback here -- the harness takes the
# artifact the caller named or HEAD's own generation, and refuses everything
# else (`resolve_stage2_strict`, #2836 §1).
#
# This gate holds that shape two ways, because either alone is a proxy:
#   1. LEXICAL -- the harness sources scripts/resolve_stage2.sh, calls the
#      STRICT resolver, and contains no mtime-ordered generation pick.
#   2. BEHAVIOURAL -- both refusals actually fire, with a nonzero exit. A
#      lexical match proves the text is present, not that it is reached.
#
# Red test: scripts/check_fuzz_compiler_identity_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

HARNESS="${FUZZ_HARNESS:-tests/fuzz/run_fuzz.sh}"
fail() { echo "check-fuzz-compiler-identity: $*" >&2; exit 1; }

[ -f "$HARNESS" ] || fail "no such harness: $HARNESS"

# 1. lexical.
grep -q 'resolve_stage2\.sh' "$HARNESS" \
  || fail "$HARNESS does not source scripts/resolve_stage2.sh"
grep -q 'resolve_stage2_strict' "$HARNESS" \
  || fail "$HARNESS does not call resolve_stage2_strict -- a measurement must refuse, not degrade"
# The lenient resolver would answer from the newest generation, then the seed,
# announcing each step on a stderr the issue thread never sees.
grep -q 'resolve_stage2 ' "$HARNESS" \
  && fail "$HARNESS calls the LENIENT resolve_stage2; a measurement needs resolve_stage2_strict"
# The shape the strict resolver replaced. Checked outside comments so the
# explanation above may quote it (the gate must not be able to see itself, and
# the harness must not be tripped by its own rationale).
if sed 's/#.*$//' "$HARNESS" | grep -q 'ls -t.*generations'; then
  fail "$HARNESS still picks a generation by MTIME (ls -t); that answers a different question than HEAD's build"
fi

# 2. behavioural. Neither probe compiles anything: both must die AT resolution.
#
# "Nonzero exit, and the refusal text appeared" is not enough, and CI proved
# it: a harness that prints the refusal and then carries on anyway satisfies
# both whenever the run it should not have started later dies for some
# unrelated reason -- a missing seed, a generator error. Locally that mutant
# exited 0 and was caught; on a CI runner it exited nonzero and the gate waved
# it through. The exit code was a proxy for "did not proceed".
#
# So the probes assert the property itself. The harness announces itself with
# `[fuzz] mode=...` on the line immediately after resolution succeeds, so that
# banner is present exactly when the run started. Refusal means it is absent.
proceeded() { case "$1" in *"[fuzz] mode="*) return 0 ;; *) return 1 ;; esac; }

out="$(bash "$HARNESS" --cli /nonexistent/stage2.wasm --seeds 1..1 2>&1)"; rc=$?
if proceeded "$out"; then
  fail "a named artifact that does not exist did not stop the run -- it announced '[fuzz] mode=' and started fuzzing"
fi
[ "$rc" -ne 0 ] || fail "a named artifact that does not exist was ACCEPTED (exit 0)"
case "$out" in
  *"override does not exist"*) ;;
  *) fail "a missing named artifact was refused without naming it: $(printf '%s' "$out" | head -1)" ;;
esac

# HEAD's generation is absent from a bare worktree, so this exercises the
# refusal without touching the real _build tree.
probe="$(mktemp -d)"
trap 'git worktree remove --force "$probe" >/dev/null 2>&1; rm -rf "$probe"' EXIT
git worktree add -q --detach "$probe" HEAD >/dev/null 2>&1 \
  || fail "could not create a probe worktree"
cp "$HARNESS" "$probe/tests/fuzz/run_fuzz.sh" \
  || fail "could not stage the harness into the probe worktree"
out2="$(cd "$probe" && bash tests/fuzz/run_fuzz.sh --seeds 1..1 2>&1)"; rc2=$?
if proceeded "$out2"; then
  fail "no generation for HEAD did not stop the run -- it announced '[fuzz] mode=' and started fuzzing against whatever it settled for"
fi
[ "$rc2" -ne 0 ] || fail "no generation for HEAD was ACCEPTED (exit 0) -- it degraded instead of refusing"
case "$out2" in
  *"no generation for HEAD"*) ;;
  *) fail "no generation for HEAD did not produce the strict refusal: $(printf '%s' "$out2" | head -1)" ;;
esac
case "$out2" in
  *"Refusing the newest generation on disk and the committed seed"*) ;;
  *) fail "the refusal did not say what it declined to measure" ;;
esac

echo "check-fuzz-compiler-identity: ok ($HARNESS resolves strictly; both refusals fire)"
