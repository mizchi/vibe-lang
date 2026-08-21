#!/usr/bin/env bash
# Self-test for check_task_inputs.sh: fixed cases over synthetic task blocks.
#
# Both directions matter. A gate that only proves it stays green would not have
# caught the thing it exists for, and one that fires on a mention rather than an
# invocation gets ignored -- the first cut flagged six sound tasks that way.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_taskinputs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fails=0
note() { printf 'check-task-inputs-test: ok: %s\n' "$1"; }
bad() { printf 'check-task-inputs-test: FAIL: %s\n' "$1" >&2; fails=1; }

run_case() { # run_case <label> <expect-exit> <taskfile-body>
  local label="$1" want="$2" body="$3"
  printf '%s\n' "$body" > "$WORK/Taskfile.pkl"
  local got=0
  TASK_INPUTS_TASKFILE="$WORK/Taskfile.pkl" bash scripts/check_task_inputs.sh >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ] && note "$label" || bad "$label: expected exit $want, got $got"
}

# Runs the compiler, explicit inputs, no vibeSources -> the bug this exists for.
run_case "compiler task without vibeSources is rejected" 1 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_freeze_surface.sh"
  inputs { "docs/cheatsheet.md" }
}'

# Selfhost sources alone omit the bootstrap compiler identity.
run_case "compiler task with only vibeSources is rejected" 1 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_freeze_surface.sh"
  inputs { ...vibeSources; "docs/cheatsheet.md" }
}'

# Compiler-probing gates use the shared superset, which also keys on the seed.
run_case "compiler task with complete compilerProbeInputs passes" 0 'local compilerProbeInputs = new {
  ...vibeSources
  "bootstrap/seed.json"
}
local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_freeze_surface.sh"
  inputs { ...compilerProbeInputs; "docs/cheatsheet.md" }
}'

# Merely naming the helper is not enough: its seed half is part of the oracle.
run_case "compilerProbeInputs without seed is rejected" 1 'local compilerProbeInputs = new {
  ...vibeSources
}
local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_freeze_surface.sh"
  inputs { ...compilerProbeInputs; "docs/cheatsheet.md" }
}'

# Caching off is the other legitimate answer.
run_case "cache = false is accepted instead" 0 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_freeze_surface.sh"
  cache = false
  inputs { "docs/cheatsheet.md" }
}'

# A task that does not reach the compiler is none of this gate's business.
run_case "pure-text task is not flagged" 0 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_book_links.sh"
  inputs { "book/**/*.md" }
}'

# A hand-written task with NO inputs inherits nothing, so its cache key is
# empty -- the worst case, not the safe one (#2138 review). An earlier version
# of this gate accepted it, and this case is what proves it no longer does.
run_case "compiler task with no inputs at all is rejected" 1 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/check_freeze_surface.sh"
}'

# An aggregator dispatches the lane scripts dynamically, so it contains none of
# the tool names literally -- it has to be classified by name.
run_case "aggregator wrapper is treated as compiler-running" 1 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/compiler_gate.sh"
  inputs { "docs/cheatsheet.md" }
}'

run_case "aggregator wrapper with only vibeSources is rejected" 1 'local t = new Task {
  name = "probe"
  cmd = "bash scripts/compiler_gate.sh"
  inputs { ...vibeSources }
}'

# A script named only in `inputs` is declared, not run. Flagging it was a real
# false positive in the first cut.
run_case "a script named only in inputs does not count as running it" 0 'local t = new Task {
  name = "probe"
  cmd = "node scripts/bench_report.mjs"
  inputs { "scripts/check_freeze_surface.sh" }
}'

[ "$fails" -eq 0 ] || exit 1
echo "check-task-inputs-test: ok (10 cases)"
