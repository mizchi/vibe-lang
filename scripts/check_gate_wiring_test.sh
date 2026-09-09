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
