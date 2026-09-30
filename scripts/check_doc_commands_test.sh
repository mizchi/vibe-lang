#!/usr/bin/env bash
# Mutate the actual modular task definitions and compiler verb dispatcher.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/doc_commands_test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/scripts/pkfire" "$SCRATCH/runtime" "$SCRATCH/lib/@vibe/compiler"
cp "$ROOT/Taskfile.pkl" "$SCRATCH/"
cp "$ROOT/scripts/pkfire/"*.pkl "$SCRATCH/scripts/pkfire/"
cp "$ROOT/scripts/check_doc_commands.sh" "$ROOT/scripts/source_files.py" "$SCRATCH/scripts/"
cp "$ROOT/runtime/vibe" "$SCRATCH/runtime/"
cp "$ROOT/lib/@vibe/compiler/user_dispatch"*.vibe "$SCRATCH/lib/@vibe/compiler/"
cd "$SCRATCH"
python3 - <<'PY'
from pathlib import Path
Path("README.md").write_text("# Commands\n\n```bash\n" +
    "pkf run test-affected\n" * 40 + "vibe inspect-update input.vibe\n```\n")
PY

expect_failure() {
  if bash scripts/check_doc_commands.sh > result.log 2>&1; then
    echo "doc-commands self-test: FAIL ($1): the mutated input passed" >&2
    exit 1
  fi
  grep -qF "$2" result.log || { cat result.log >&2; exit 1; }
}

bash scripts/check_doc_commands.sh > result.log 2>&1
grep -qF '41 references' result.log

cp scripts/pkfire/quality_tasks.pkl quality.original
python3 - <<'PY'
from pathlib import Path
p = Path("scripts/pkfire/quality_tasks.pkl")
s = p.read_text()
needle = 'name = "test-affected"'
assert s.count(needle) == 1, "the task-name mutation must land"
p.write_text(s.replace(needle, 'name = "test-affected-disabled"'))
assert needle not in p.read_text()
PY
expect_failure 'removed imported task' '`pkf run test-affected` -- no such task'
cp quality.original scripts/pkfire/quality_tasks.pkl

dispatcher=lib/@vibe/compiler/user_dispatch_selfhost_cli_user_grep_args.vibe
cp "$dispatcher" dispatcher.original
python3 - "$dispatcher" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '"inspect-update" =>'
assert s.count(needle) == 1, "the dispatcher mutation must land"
p.write_text(s.replace(needle, '"inspect-update-disabled" =>'))
assert needle not in p.read_text()
PY
expect_failure 'removed split dispatcher verb' '`vibe inspect-update` -- no such command'
cp dispatcher.original "$dispatcher"

rm scripts/pkfire/quality_tasks.pkl
expect_failure 'missing imported task module' 'quality_tasks.pkl'
cp quality.original scripts/pkfire/quality_tasks.pkl
bash scripts/check_doc_commands.sh > result.log 2>&1
echo 'doc-commands self-test: imported tasks, split verbs, and refusal controls passed'
