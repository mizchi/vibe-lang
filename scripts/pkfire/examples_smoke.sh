#!/usr/bin/env bash
# PR-oriented selfhost smoke examples — extracted from justfile
# `ci-examples-smoke`.
set -euo pipefail

SELFHOST_WASM="_build/dist/selfhost_compiler.wasm"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
mkdir -p _build/s1test
ok=0
fail=0
total=0
examples=(
  examples/module_export.vibe
  examples/module_types_export.vibe
  examples/async.vibe
  examples/features.vibe
)
for f in "${examples[@]}"; do
  name=$(basename "$f" .vibe)
  total=$((total + 1))
  rm -f "_build/s1test/${name}.wasm"
  compile_out=$(VIBE_PREOPEN_DIR="$(pwd)" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main \
    "$SELFHOST_WASM" "$f" "_build/s1test/${name}.wasm" "_start" 2>&1 || true)
  if [ -f "_build/s1test/${name}.wasm" ] && [ "$(wc -c < "_build/s1test/${name}.wasm")" -gt 100 ]; then
    run_result=$(wasmtime run -W exceptions=y --invoke _start "_build/s1test/${name}.wasm" 2>&1 || true)
    if [ -z "$run_result" ] || echo "$run_result" | grep -q "^0$\|^warning"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      echo "::error::$name: run failed"
    fi
  else
    fail=$((fail + 1))
    echo "::error::$name: compile failed — $(echo "$compile_out" | tail -1)"
  fi
done
{
  echo "### Selfhost Examples"
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| Total | $total |"
  echo "| Pass | $ok |"
  echo "| Fail | $fail |"
} >> "$summary"
[ "$fail" -eq 0 ]
