#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$ROOT_DIR/_build/kpi-work-dir-test"' EXIT
STAGE2="$TMP/stage2.wasm"
INPUT="$TMP/input.vibe"
RUNNER="$TMP/mock-runner.sh"
printf 'wasm' >"$STAGE2"
printf 'fn main() -> Unit { () }\n' >"$INPUT"
cat >"$RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
printf 'wasm output' >"$5"
echo '[wasm-memory] heap_ptr=12345 pages=2' >&2
RUNNER
chmod +x "$RUNNER"

WORK="$ROOT_DIR/_build/kpi-work-dir-test/work"
mkdir -p "$WORK"
out="$(
  VIBE_KPI_WORK_DIR="$WORK" \
  VIBE_KPI_ALLOWED_WORK_ROOT="$ROOT_DIR/_build/kpi-work-dir-test" \
  VIBE_KPI_RUNNER_SCRIPT="$RUNNER" \
  bash "$ROOT_DIR/scripts/selfcompile_kpi.sh" "$STAGE2" "$INPUT"
)"
grep -q 'heap_ptr_bytes=12345' <<<"$out"
[ ! -e "$WORK" ] || { echo "fixed work directory was not removed" >&2; exit 1; }

expect_reject() {
  local expected="$1"
  shift
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || { echo "expected exit 2, got $rc: $output" >&2; exit 1; }
  grep -q "$expected" <<<"$output" || { echo "missing rejection '$expected': $output" >&2; exit 1; }
}

mkdir -p "$TMP/outside"
expect_reject 'must be under' env \
  VIBE_KPI_WORK_DIR="$TMP/outside/work" \
  VIBE_KPI_ALLOWED_WORK_ROOT="$ROOT_DIR/_build/kpi-work-dir-test" \
  VIBE_KPI_RUNNER_SCRIPT="$RUNNER" \
  bash "$ROOT_DIR/scripts/selfcompile_kpi.sh" "$STAGE2" "$INPUT"

mkdir -p "$ROOT_DIR/_build/kpi-work-dir-test/nonempty"
printf stale >"$ROOT_DIR/_build/kpi-work-dir-test/nonempty/stale"
expect_reject 'must be empty' env \
  VIBE_KPI_WORK_DIR="$ROOT_DIR/_build/kpi-work-dir-test/nonempty" \
  VIBE_KPI_ALLOWED_WORK_ROOT="$ROOT_DIR/_build/kpi-work-dir-test" \
  VIBE_KPI_RUNNER_SCRIPT="$RUNNER" \
  bash "$ROOT_DIR/scripts/selfcompile_kpi.sh" "$STAGE2" "$INPUT"

ln -s "$TMP/outside" "$ROOT_DIR/_build/kpi-work-dir-test/link"
expect_reject 'must not be a symlink' env \
  VIBE_KPI_WORK_DIR="$ROOT_DIR/_build/kpi-work-dir-test/link" \
  VIBE_KPI_ALLOWED_WORK_ROOT="$ROOT_DIR/_build/kpi-work-dir-test" \
  VIBE_KPI_RUNNER_SCRIPT="$RUNNER" \
  bash "$ROOT_DIR/scripts/selfcompile_kpi.sh" "$STAGE2" "$INPUT"

echo "selfcompile_kpi fixed work directory: ok"
