#!/usr/bin/env bash
# Regression test for #1182: scripts/vibe_run.sh (and any other caller doing
# `--invoke <entry>` after a compile, where <entry> is the ADR-0075 `main`
# convention) must run the program's entry EXACTLY once.
#
# Root cause: wasm_vibe_host_runner.js pre-invokes `_start()` before any
# non-`_start` --invoke target, to initialize module-level globals for
# test/bench modules whose target is NOT what `_start` itself calls. But for
# an ordinary `entry=main` .vibex build, `_start` already calls `main`
# directly (see linked_compile.vibe's `_start` synthesis), so invoking `main`
# again afterward ran the entry -- and every side effect it performs -- a
# second time. Confirmed live via `bash scripts/vibe_run.sh` printing a
# single `stdout_write` call's line twice before the fix.
#
# This test compiles a trivial with-effect `.vibex` that writes one marker
# line to stdout and asserts the marker appears in the run's output EXACTLY
# once.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="_build/test/vibe_run_single_invoke"
mkdir -p "$WORK_DIR"
src="$WORK_DIR/single_invoke_probe.vibex"

cat > "$src" <<'EOF'
import @vibe/builtin { stdout_write }

fn main with Stdout {
  stdout_write("SINGLE_INVOKE_PROBE_MARKER\n")
}
EOF

out="$(bash scripts/vibe_run.sh "$src")"
count="$(printf '%s\n' "$out" | grep -c '^SINGLE_INVOKE_PROBE_MARKER$' || true)"

if [ "$count" -ne 1 ]; then
  echo "test_vibe_run_single_invoke: FAIL -- expected marker exactly once, got $count" >&2
  echo "--- full output ---" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "test_vibe_run_single_invoke: OK (entry invoked exactly once)"
