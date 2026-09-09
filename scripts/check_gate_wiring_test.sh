#!/usr/bin/env bash
# Red/green for check_gate_wiring.sh. Every red case asserts the FIXTURE LANDED
# before believing the verdict -- a mutation that matches nothing passes while
# proving nothing, which is how #2248 shipped a check that could not fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/check_gate_wiring.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_gate_wiring_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "gate-wiring self-test: $1" >&2; exit 1; }
ok() { echo "  ok  $1"; }
run() { VIBE_GATE_WIRING_ROOT="$TMP_ROOT" bash "$CHECK" >"$TMP_ROOT/out" 2>&1; }

# A minimal tree with every edge kind the real one uses: a workflow naming a
# script directly, a workflow naming a pkf task, a task naming a script, and a
# script naming another script.
reset_tree() {
  rm -rf "$TMP_ROOT/scripts" "$TMP_ROOT/.github" "$TMP_ROOT/Taskfile.pkl" "$TMP_ROOT/deep"
  mkdir -p "$TMP_ROOT/scripts" "$TMP_ROOT/.github/workflows"
  cat > "$TMP_ROOT/.github/workflows/ci.yml" <<'EOF'
jobs:
  lint:
    steps:
      - run: bash scripts/check_direct.sh
      - run: pkf run some-task
EOF
  cat > "$TMP_ROOT/Taskfile.pkl" <<'EOF'
local someTask = new Task {
  name = "some-task"
  cmd = "bash scripts/check_via_task.sh"
}
EOF
  printf '#!/usr/bin/env bash\nbash "$SCRIPT_DIR/lint_transitive.sh"\n' > "$TMP_ROOT/scripts/check_direct.sh"
  printf '#!/usr/bin/env bash\necho via-task\n' > "$TMP_ROOT/scripts/check_via_task.sh"
  printf '#!/usr/bin/env bash\necho transitive\n' > "$TMP_ROOT/scripts/lint_transitive.sh"
  rm -f "$TMP_ROOT/scripts/gate_wiring_allowlist.txt"
}

# --- green: all three reachable, including the transitive one and the one only
# a task names. Without this the checker could pass by rejecting nothing.
reset_tree
run || { cat "$TMP_ROOT/out" >&2; fail "a fully wired tree was rejected"; }
grep -qF "3 gate script(s) reachable" "$TMP_ROOT/out" || { cat "$TMP_ROOT/out" >&2; fail "the green run did not count all three"; }
ok "a wired tree passes: direct, via a pkf task, and transitively through a script"

# --- red 1: a gate no workflow reaches.
reset_tree
printf '#!/usr/bin/env bash\necho dark\n' > "$TMP_ROOT/scripts/check_dark.sh"
[ -f "$TMP_ROOT/scripts/check_dark.sh" ] || fail "fixture 1 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a gate reachable from nothing was accepted"; }
grep -qF "check_dark.sh" "$TMP_ROOT/out" || { cat "$TMP_ROOT/out" >&2; fail "the finding did not name the dark gate"; }
ok "a gate no workflow reaches is rejected"

# --- green 1b: the allowlist admits it, in writing, with a reason.
printf 'check_dark.sh runs by hand only, on purpose\n' > "$TMP_ROOT/scripts/gate_wiring_allowlist.txt"
run || { cat "$TMP_ROOT/out" >&2; fail "an allowlisted local-only gate was rejected"; }
grep -qF "1 allowlisted" "$TMP_ROOT/out" || fail "the allowlisted count was not reported"
ok "an allowlisted gate is accepted, and counted"

# --- red 1c: an allowlist row that is now REACHED must fail, or the allowlist
# becomes a place gates hide after someone wires them.
reset_tree
printf 'check_direct.sh stale row: this one IS wired\n' > "$TMP_ROOT/scripts/gate_wiring_allowlist.txt"
run && { cat "$TMP_ROOT/out" >&2; fail "a stale allowlist row was accepted"; }
grep -qF "check_direct.sh" "$TMP_ROOT/out" || fail "the stale-row finding did not name it"
ok "an allowlist row for a gate that IS reached is rejected"

# --- red 1d: an allowlist row naming no such script.
reset_tree
printf 'check_ghost.sh nothing by this name exists\n' > "$TMP_ROOT/scripts/gate_wiring_allowlist.txt"
run && { cat "$TMP_ROOT/out" >&2; fail "an allowlist row for a nonexistent gate was accepted"; }
ok "an allowlist row naming no gate is rejected"

# --- red 2: unwiring a real invocation. This is the regression the three dark
# gates actually were: the script still exists, nothing runs it.
reset_tree
grep -qF 'bash scripts/check_direct.sh' "$TMP_ROOT/.github/workflows/ci.yml" || fail "fixture 2 precondition missing"
sed -i.bak '/check_direct\.sh/d' "$TMP_ROOT/.github/workflows/ci.yml"
grep -qF 'check_direct.sh' "$TMP_ROOT/.github/workflows/ci.yml" && fail "fixture 2 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "unwiring a gate from the workflow was accepted"; }
grep -qF "check_direct.sh" "$TMP_ROOT/out" || fail "the unwired finding did not name it"
ok "removing a workflow's invocation of a wired gate is rejected"

# --- red 2b: unwiring the TASK also unreaches what only the task named.
reset_tree
sed -i.bak '/pkf run some-task/d' "$TMP_ROOT/.github/workflows/ci.yml"
grep -qF 'pkf run some-task' "$TMP_ROOT/.github/workflows/ci.yml" && fail "fixture 2b did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "unwiring the task was accepted"; }
grep -qF "check_via_task.sh" "$TMP_ROOT/out" || fail "the finding did not name the task-only gate"
ok "removing the pkf task from the workflow unreaches the gate behind it"

# --- red 3: a reference the scanner cannot resolve must FAIL, not be skipped.
# Silence and "unchecked" are indistinguishable (#2248), which is the whole
# defect this gate exists for.
reset_tree
printf '      - run: pkf run "$COMPUTED"\n' >> "$TMP_ROOT/.github/workflows/ci.yml"
grep -qF 'pkf run "$COMPUTED"' "$TMP_ROOT/.github/workflows/ci.yml" || fail "fixture 3 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a computed task name was skipped silently"; }
grep -qF "computed task" "$TMP_ROOT/out" || fail "the finding did not name the reason"
ok "a computed pkf task name fails rather than being skipped"

# --- red 3b: a computed script BASENAME. The scanner resolves by basename, so
# this is the one shape that would silently unreach whatever it names.
reset_tree
printf 'bash "$dir/$name.sh"\n' >> "$TMP_ROOT/scripts/check_direct.sh"
grep -qF '$name.sh' "$TMP_ROOT/scripts/check_direct.sh" || fail "fixture 3b did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a computed script basename was skipped silently"; }
grep -qF "computes a script BASENAME" "$TMP_ROOT/out" || fail "the finding did not name the reason"
ok "a computed script basename fails rather than being skipped"

# --- red 3c: a workflow naming a task the Taskfile does not define is a broken
# wire; reporting it as "no gates behind it" would hide the break.
reset_tree
printf '      - run: pkf run no-such-task\n' >> "$TMP_ROOT/.github/workflows/ci.yml"
grep -qF 'pkf run no-such-task' "$TMP_ROOT/.github/workflows/ci.yml" || fail "fixture 3c did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a workflow naming an undefined task was accepted"; }
ok "a workflow naming an undefined pkf task is rejected"

# --- green/red 5: an AMBIGUOUS BASENAME must read EVERY file carrying it.
# This is the shape `tests/gates/{bootstrap,early,mid,late}/run.sh` has, invoked
# by compiler_gate.sh as `bash "$ROOT_DIR/tests/gates/$lane/run.sh"` -- computed
# directory, literal basename. Keeping only the first match made the answer
# depend on os.walk ORDER: the first draft passed locally and reported five
# gates dark in CI. A gate that answers differently on two machines is worse
# than no gate.
reset_tree
mkdir -p "$TMP_ROOT/lanes/a" "$TMP_ROOT/lanes/b"
printf '#!/usr/bin/env bash\necho lane a, names no gate\n' > "$TMP_ROOT/lanes/a/run.sh"
printf '#!/usr/bin/env bash\nbash scripts/check_only_in_lane_b.sh\n' > "$TMP_ROOT/lanes/b/run.sh"
printf '#!/usr/bin/env bash\necho reached only through lane b\n' > "$TMP_ROOT/scripts/check_only_in_lane_b.sh"
printf '      - run: bash "$ROOT/lanes/$lane/run.sh"\n' >> "$TMP_ROOT/.github/workflows/ci.yml"
grep -qF 'lanes/$lane/run.sh' "$TMP_ROOT/.github/workflows/ci.yml" || fail "fixture 5 did not land"
[ -f "$TMP_ROOT/lanes/a/run.sh" ] && [ -f "$TMP_ROOT/lanes/b/run.sh" ] || fail "fixture 5 lanes did not land"
run || { cat "$TMP_ROOT/out" >&2; fail "a gate reached only through the SECOND file sharing a basename was reported dark"; }
ok "an ambiguous basename reads every file carrying it, not whichever the walk hit first"

# The same tree, five times, must give the same answer. Order-dependence is the
# defect; one passing run does not rule it out.
for _ in 1 2 3 4 5; do
  run || { cat "$TMP_ROOT/out" >&2; fail "the ambiguous-basename tree answered differently between runs"; }
done
ok "the answer is stable across repeated runs"

# --- red 6: a MESSAGE is not an invocation. The first draft accepted any
# non-comment line carrying a basename, so a reachable wrapper containing only
# `echo "run bash scripts/check_dark.sh"` certified a wire that does not exist
# (Codex P1 on #2591) -- documentation text marking a gate as run.
reset_tree
printf '#!/usr/bin/env bash\necho dark\n' > "$TMP_ROOT/scripts/check_dark.sh"
printf 'echo "to run it by hand: bash scripts/check_dark.sh"\n' >> "$TMP_ROOT/scripts/check_direct.sh"
grep -qF 'to run it by hand' "$TMP_ROOT/scripts/check_direct.sh" || fail "fixture 6 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a basename inside an echo certified a wire"; }
grep -qF "check_dark.sh" "$TMP_ROOT/out" || fail "the finding did not name the still-dark gate"
ok "a basename inside an echo is not an invocation"

# --- red 7: a gate SELF-TEST is not evidence its production gate runs. A
# self-test names its gate because it runs it against fixtures; left as an edge,
# unwiring the real CI step would go unnoticed -- the dark-gate case itself
# (Codex P1 on #2591). Measured on the real tree: this is what exposed
# check_book_console.sh, wired only via its self-test, and red.
reset_tree
printf '#!/usr/bin/env bash\necho dark\n' > "$TMP_ROOT/scripts/check_dark.sh"
printf '#!/usr/bin/env bash\nbash scripts/check_dark.sh --fixture\n' > "$TMP_ROOT/scripts/check_dark_test.sh"
printf '      - run: bash scripts/check_dark_test.sh\n' >> "$TMP_ROOT/.github/workflows/ci.yml"
grep -qF 'check_dark_test.sh' "$TMP_ROOT/.github/workflows/ci.yml" || fail "fixture 7 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a self-test certified its production gate as wired"; }
grep -qF "check_dark.sh" "$TMP_ROOT/out" || fail "the finding did not name the gate the self-test hid"
ok "a gate self-test does not certify its production gate as wired"

# --- red 8: a DYNAMIC run must be declared, and the declaration is checked.
reset_tree
printf 'script="$(pick_lane)"\nbash "$script"\n' >> "$TMP_ROOT/scripts/check_direct.sh"
grep -qF 'bash "$script"' "$TMP_ROOT/scripts/check_direct.sh" || fail "fixture 8 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "an undeclared dynamic invocation was skipped"; }
grep -qF "declares nothing" "$TMP_ROOT/out" || fail "the finding did not name the reason"
ok "a dynamic run with no declaration fails rather than being skipped"

reset_tree
mkdir -p "$TMP_ROOT/lanes/x"
printf '#!/usr/bin/env bash\nbash scripts/check_behind_dispatch.sh\n' > "$TMP_ROOT/lanes/x/go.sh"
printf '#!/usr/bin/env bash\necho behind\n' > "$TMP_ROOT/scripts/check_behind_dispatch.sh"
printf '# gate-wiring: reaches lanes/x/go.sh\nscript="$(pick_lane)"\nbash "$script"\n' >> "$TMP_ROOT/scripts/check_direct.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "a declared dynamic invocation was not followed"; }
ok "a declared dynamic run resolves, and what is behind it counts as reached"

reset_tree
printf '# gate-wiring: reaches lanes/nope/go.sh\nscript="$(pick_lane)"\nbash "$script"\n' >> "$TMP_ROOT/scripts/check_direct.sh"
run && { cat "$TMP_ROOT/out" >&2; fail "a declaration naming no file was accepted"; }
grep -qF "names no such file" "$TMP_ROOT/out" || fail "the finding did not name the reason"
ok "a declaration naming a file that does not exist is rejected"

# --- red 9: an allowlist row with no reason is not a written admission.
reset_tree
printf '#!/usr/bin/env bash\necho dark\n' > "$TMP_ROOT/scripts/check_dark.sh"
printf 'check_dark.sh\n' > "$TMP_ROOT/scripts/gate_wiring_allowlist.txt"
run && { cat "$TMP_ROOT/out" >&2; fail "an allowlist row with no reason was accepted"; }
grep -qF "no reason" "$TMP_ROOT/out" || fail "the finding did not name the reason"
ok "an allowlist row with no reason is rejected"

# --- red 4: a scan whose ROOTS vanish must fail, not report everything dark or
# everything fine. An empty corpus is the shape that let five broken self-tests
# sit green (#2252).
reset_tree
rm -f "$TMP_ROOT/.github/workflows/ci.yml"
run && { cat "$TMP_ROOT/out" >&2; fail "a tree with no workflows was accepted"; }
grep -qF "no workflows found" "$TMP_ROOT/out" || fail "the empty-roots finding did not name the reason"
ok "a tree with no workflows fails rather than passing vacuously"

reset_tree
rm -f "$TMP_ROOT"/scripts/check_*.sh "$TMP_ROOT"/scripts/lint_*.sh
run && { cat "$TMP_ROOT/out" >&2; fail "an empty gate corpus was accepted"; }
grep -qF "corpus went empty" "$TMP_ROOT/out" || fail "the empty-corpus finding did not name the reason"
ok "an empty gate corpus fails rather than passing vacuously"

echo "[gate-wiring-test] ok"
