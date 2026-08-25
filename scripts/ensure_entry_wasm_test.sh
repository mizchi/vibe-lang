#!/usr/bin/env bash
# Self-test for scripts/ensure_entry_wasm.sh's FAILURE path, and for the two
# callers that consume its exit code (#2271).
#
# The bug it pins: the compile line ran as a bare command under `set -e`, so a
# non-zero runner abandoned the script one line above the `[ -s ... ] || echo
# ... exit 1` that existed to explain the failure. Callers got exit 1 and an
# empty stderr -- which is exactly what `vibe fmt --check` means by "not
# formatted" -- so `vibe fmt` looped forever on a file that was never at fault,
# with the real cause sitting in the `<wasm>.diag` sidecar that nothing read.
#
# Everything here works on scratch entries under _build/, never on the real
# formatter artifact, so it cannot leave the tree in a state another gate
# section would trip over.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_REL="_build/ensure_entry_wasm_test"
WORK="$ROOT_DIR/$WORK_REL"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[ensure-entry-wasm-test] FAIL: $*" >&2; exit 1; }

# --- 1. a compile failure is LOUD, and names the compiler's own diagnostic ---
printf 'fn f( -> Int {\n' > "$WORK/bad.vibe"
rc=0
bash scripts/ensure_entry_wasm.sh "$WORK_REL/bad.vibe" "$WORK_REL/bad.wasm" \
  >"$WORK/bad.out" 2>"$WORK/bad.err" || rc=$?
[ "$rc" = "1" ] || fail "unbuildable entry exited $rc, want 1"
grep -q "failed to compile $WORK_REL/bad.vibe" "$WORK/bad.err" \
  || fail "stderr does not name the entry it could not compile"
# The compiler's own words, not just "it failed" -- that is the difference
# between an actionable message and the silent exit this test exists for.
grep -q "expected parameter name" "$WORK/bad.err" \
  || fail "stderr does not carry the compiler's diagnostic"
grep -q "ensure_generated.sh" "$WORK/bad.err" \
  || fail "stderr does not point at the usual cause on a fresh checkout"
[ ! -e "$WORK/bad.wasm" ] || fail "a failed compile left an artifact behind"

# --- 2. a failed REBUILD retracts the previous build's verdict ---
# Otherwise the caller keeps answering from a formatter built before the edit,
# which is the stale-reuse ensure_entry_wasm.sh's staleness rules exist to
# prevent. The bogus wasm stands in for a good build from an earlier run.
#
# What must go is the MANIFEST, not the wasm: an absent manifest is the first
# staleness test, so the next run rebuilds, while the bytes stay put for a
# concurrent caller that is running them right now (#2277 review). The check is
# therefore behavioural -- ask again and it must still refuse to call it fresh.
printf 'stale artifact\n' > "$WORK/stale.wasm"
printf '%s\n' "$WORK_REL/stale.vibe" > "$WORK/stale.wasm.deps"
printf 'fn g( -> Int {\n' > "$WORK/stale.vibe"
# Backdate the artifact rather than trusting write order: everything here is
# written inside one second, and the staleness tests are strict `-nt`, so
# same-second mtimes read as fresh and nothing would rebuild at all.
touch -t 200001010000 "$WORK/stale.wasm" "$WORK/stale.wasm.deps"
rc=0
bash scripts/ensure_entry_wasm.sh "$WORK_REL/stale.vibe" "$WORK_REL/stale.wasm" \
  >/dev/null 2>"$WORK/stale.err" || rc=$?
[ "$rc" = "1" ] || fail "failed rebuild exited $rc, want 1"
[ ! -e "$WORK/stale.wasm.deps" ] || fail "failed rebuild kept the manifest, so the next run would reuse the old artifact"
rc=0
bash scripts/ensure_entry_wasm.sh "$WORK_REL/stale.vibe" "$WORK_REL/stale.wasm" \
  >/dev/null 2>/dev/null || rc=$?
[ "$rc" = "1" ] || fail "the run after a failed rebuild answered $rc -- it reused the stale artifact"

# --- 3. the success path still works, and still prints the path ---
printf 'fn main() -> Int {\n  0\n}\n' > "$WORK/good.vibe"
out="$(bash scripts/ensure_entry_wasm.sh "$WORK_REL/good.vibe" "$WORK_REL/good.wasm" 2>/dev/null)"
[ "$out" = "$WORK_REL/good.wasm" ] || fail "success printed '$out', want '$WORK_REL/good.wasm'"
[ -s "$WORK/good.wasm" ] || fail "success produced no wasm"
[ -s "$WORK/good.wasm.deps" ] || fail "success captured no dependency closure"
# The funcmap sidecar has to be published with the wasm, and nothing named for
# the temporary build path may survive -- a leaked `.tmp` sidecar is a stale
# symbol table sitting next to a fresh artifact.
[ -s "$WORK/good.wasm.funcmap" ] || fail "success left the funcmap sidecar unpublished"
leftover="$(find "$WORK" -name '*.tmp*' -print -quit)"
[ -z "$leftover" ] || fail "the build left a temporary artifact behind: $leftover"

# --- 4. the callers must not swallow that exit code in a bare assignment ---
# `var="$(bash .../ensure_...)"` under `set -e` dies with exit 1 and nothing on
# stderr, which is indistinguishable from a formatting verdict. Each caller has
# to handle the failure explicitly.
assert_handles() {
  local file="$1" ensure="$2"
  grep -qE "^[a-z_]+=\"\\\$\(bash \"\\\$ROOT_DIR/scripts/$ensure\"\)\"\$" "$file" \
    && return 1
  grep -q "scripts/$ensure" "$file" || return 2
  return 0
}
for pair in "scripts/vibe_fmt.sh ensure_vibe_fmt_entry.sh" \
            "scripts/run_vibe_fmt_batch.sh ensure_vibe_fmt_batch.sh"; do
  set -- $pair
  case "$(assert_handles "$1" "$2" && echo 0 || echo $?)" in
    0) ;;
    1) fail "$1 calls $2 in a bare assignment; a build failure exits 1 with no message" ;;
    2) fail "$1 no longer calls $2 -- update this test" ;;
  esac
done

# --- 5. every consumer of the batch must reconcile the report COUNT ---
# `done < <(... | run_vibe_fmt_batch.sh ...)` hides the batch's exit status, so a
# dead batch feeds the loop zero lines and the caller reports "0 file(s)" and
# exits 0 -- green having done nothing. check_vibe_fmt.sh was fixed for this and
# vibe_fmt_apply.sh was missed, which is `pkf run fmt` silently rewriting
# nothing (#2271, #2277 review). The check is lexical -- shell dataflow is not
# decidable here -- so it requires the one structural thing that cannot be
# faked into existence: a comparison against the input list's length.
reconciles() {
  grep -q 'run_vibe_fmt_batch\.sh' "$1" || return 2
  grep -qE -- '-ne "\$\{#[a-z_]+\[@\]\}"' "$1" || return 1
  return 0
}
for f in scripts/check_vibe_fmt.sh scripts/vibe_fmt_apply.sh; do
  case "$(reconciles "$f" && echo 0 || echo $?)" in
    0) ;;
    1) fail "$f consumes the batch without reconciling the report count against its input" ;;
    2) fail "$f no longer consumes run_vibe_fmt_batch.sh -- update this test" ;;
  esac
done

# Red-test rule 5: strip the guard and it must be rejected.
mkdir -p "$WORK/mut5"
grep -v -E -- '-ne "\$\{#[a-z_]+\[@\]\}"' scripts/vibe_fmt_apply.sh > "$WORK/mut5/vibe_fmt_apply.sh"
if ! grep -q 'run_vibe_fmt_batch\.sh' "$WORK/mut5/vibe_fmt_apply.sh"; then
  fail "red-test mutation removed the batch call it needed to keep"
fi
if reconciles "$WORK/mut5/vibe_fmt_apply.sh"; then
  fail "rule 5 accepts a caller with no count reconciliation"
fi

# --- 6. the rebuild must never write over the published artifact in place ---
# Callers run concurrently (scripts/vibe_md.sh spawns one worker per document),
# so two of them can both see "stale" at once. Compiling straight to the shared
# path hands the other worker a half-written wasm, and deleting it first hands
# it a missing one; both surface as an intermittent gate failure with no signal
# in it (#2277 review). Lexical, like rules 4-5: what it pins is that the
# compile target is a per-process path and that the publish is a rename.
publishes_by_rename() {
  grep -qE 'build_wasm_rel="\$wasm_rel\.\$\$' "$1" || return 1
  grep -qE -- '--invoke cli_main "\$seed" "\$entry_src" "\$build_wasm_rel"' "$1" || return 1
  grep -qE '^\s*mv -f "\$ROOT_DIR/\$build_wasm_rel" "\$ROOT_DIR/\$wasm_rel"$' "$1" || return 1
  # ...and it must notice when someone published over it between that rename and
  # the sidecars, since the three renames are not one transaction. The inode is
  # the only evidence available without a lock: `mv` in-directory is rename(2),
  # so the published file keeps ours unless it was replaced.
  grep -q 'build_inode=' "$1" || return 1
  grep -q 'published_inode=' "$1" || return 1
  grep -qE '\[ "\$published_inode" != "\$build_inode" \]' "$1" || return 1
  # ...and again after the sidecars, since the first check only catches a winner
  # that landed before it.
  grep -qE '\[ "\$final_inode" != "\$build_inode" \]' "$1" || return 1
  return 0
}
publishes_by_rename scripts/ensure_entry_wasm.sh \
  || fail "the rebuild does not compile to a per-process path and publish it by rename"

# Red-test rule 6 twice: once against the compile target, once against the
# interleave check. A mutation that matches nothing proves nothing, so each
# `sed` is verified to have actually removed the line it targets.
mkdir -p "$WORK/mut6"
sed 's|"\$entry_src" "\$build_wasm_rel" main|"$entry_src" "$wasm_rel" main|' \
  scripts/ensure_entry_wasm.sh > "$WORK/mut6/ensure_entry_wasm.sh"
if publishes_by_rename "$WORK/mut6/ensure_entry_wasm.sh"; then
  fail "rule 6 accepts a rebuild that compiles straight to the published path"
fi
grep -v 'published_inode=' scripts/ensure_entry_wasm.sh > "$WORK/mut6/no_inode.sh"
if ! grep -q 'build_inode=' "$WORK/mut6/no_inode.sh"; then
  fail "red-test mutation removed more than the line it targeted"
fi
if publishes_by_rename "$WORK/mut6/no_inode.sh"; then
  fail "rule 6 accepts a publish that cannot notice an interleaved winner"
fi

# Red-test rule 4 against a mutated copy: a checker that cannot fail is not a
# check. Restoring the bare form must be rejected.
mkdir -p "$WORK/mut/scripts"
sed 's/^entry_wasm_rel=.*$/entry_wasm_rel="$(bash "$ROOT_DIR\/scripts\/ensure_vibe_fmt_entry.sh")"/' \
  scripts/vibe_fmt.sh > "$WORK/mut/scripts/vibe_fmt.sh"
grep -q 'ensure_vibe_fmt_entry' "$WORK/mut/scripts/vibe_fmt.sh" \
  || fail "red-test mutation lost the call it was supposed to reintroduce"
if assert_handles "$WORK/mut/scripts/vibe_fmt.sh" "ensure_vibe_fmt_entry.sh"; then
  fail "rule 4 accepts the bare assignment it exists to reject"
fi

echo "[ensure-entry-wasm-test] ok (loud failure + diagnostic + stale retraction + success path + caller exit-code handling + batch count reconciliation + atomic publish + interleave detection, red-tested)"
