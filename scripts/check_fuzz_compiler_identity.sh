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
# The OTHER entry point to the same oracle. tests/fuzz/reduce.py starts one
# per reduction candidate, and a reduction is where a finding gets its NAME,
# so it needs the same rule -- it had the mtime default until #2959, and this
# gate's green said nothing about it because the gate read one file.
# Overridable for the red test; empty means "only the harness".
CLASSIFY="${FUZZ_CLASSIFY-tests/fuzz/classify.sh}"
fail() { echo "check-fuzz-compiler-identity: $*" >&2; exit 1; }

[ -f "$HARNESS" ] || fail "no such harness: $HARNESS"

# 1. lexical -- applied to EVERY entry point, not just the sweeping one.
lexical() { # <path>
  local f="$1"
  grep -q 'resolve_stage2\.sh' "$f" \
    || fail "$f does not source scripts/resolve_stage2.sh"
  grep -q 'resolve_stage2_strict' "$f" \
    || fail "$f does not call resolve_stage2_strict -- a measurement must refuse, not degrade"
  # The lenient resolver would answer from the newest generation, then the
  # seed, announcing each step on a stderr the issue thread never sees.
  grep -q 'resolve_stage2 ' "$f" \
    && fail "$f calls the LENIENT resolve_stage2; a measurement needs resolve_stage2_strict"
  # The shape the strict resolver replaced. Checked outside comments so the
  # explanation above may quote it (the gate must not be able to see itself,
  # and the file must not be tripped by its own rationale).
  if sed 's/#.*$//' "$f" | grep -q 'ls -t.*generations'; then
    fail "$f still picks a generation by MTIME (ls -t); that answers a different question than HEAD's build"
  fi
}

lexical "$HARNESS"
if [ -n "$CLASSIFY" ]; then
  [ -f "$CLASSIFY" ] || fail "no such classifier: $CLASSIFY"
  lexical "$CLASSIFY"
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

# 3. behavioural, for the classifier: it takes a DIR rather than --seeds, so
# it gets its own probe rather than sharing the harness's. Same property --
# a named artifact that does not exist must stop it, not be shrugged off.
if [ -n "$CLASSIFY" ]; then
  cdir="$(mktemp -d)"
  printf 'fn main {\n  println("x")\n}\n' > "$cdir/single.vibe"
  cout="$(bash "$CLASSIFY" "$cdir" --cli /nonexistent/stage2.wasm 2>&1)"; crc=$?
  rm -rf "$cdir"
  [ "$crc" -ne 0 ] || fail "$CLASSIFY accepted a named artifact that does not exist (exit 0)"
  case "$cout" in
    *"does not exist"*) ;;
    *) fail "$CLASSIFY did not refuse a missing named artifact: $(printf '%s' "$cout" | head -1)" ;;
  esac
  # A class would be a verdict from a compiler that was never loaded.
  case "$cout" in
    *COMPILE_*|*RUN_*|*MISMATCH*|*OK\ *) fail "$CLASSIFY printed a CLASS after failing to resolve a compiler: $(printf '%s' "$cout" | head -1)" ;;
  esac
fi

echo "check-fuzz-compiler-identity: ok ($HARNESS and ${CLASSIFY:-<no classifier>} resolve strictly; refusals fire)"
