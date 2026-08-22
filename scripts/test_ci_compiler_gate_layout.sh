#!/usr/bin/env bash
set -euo pipefail

workflow=".github/workflows/ci.yml"
bootstrap="tests/gates/bootstrap/run.sh"

require() {
  local pattern="$1"
  local file="$2"
  if ! grep -qE "$pattern" "$file"; then
    echo "[ci-compiler-gate-layout] missing '$pattern' in $file" >&2
    exit 1
  fi
}

reject_compiler_gate_block() {
  local pattern="$1"
  local block
  block="$(sed -n '/^  compiler-gate:/,/^  [a-zA-Z0-9_-]*:/p' "$workflow")"
  if grep -qE "$pattern" <<<"$block"; then
    echo "[ci-compiler-gate-layout] compiler-gate still contains '$pattern'" >&2
    exit 1
  fi
}

require_job_block() {
  local job="$1"
  local pattern="$2"
  local block
  block="$(sed -n "/^  ${job}:/,/^  [a-zA-Z0-9_-]*:/p" "$workflow")"
  if ! grep -qE "$pattern" <<<"$block"; then
    echo "[ci-compiler-gate-layout] ${job} missing '$pattern'" >&2
    exit 1
  fi
}

require '^  compiler-gate-preflight:$' "$workflow"
require '^  compiler-examples:$' "$workflow"
require '^  compiler-stage2-oracles:$' "$workflow"
require '^  compiler-docs:$' "$workflow"
require '^  compiler-playground:$' "$workflow"
require '^  review-regressions:$' "$workflow"
require 'pkf run ci-compiler-gate-preflight' "$workflow"
require 'pkf run ci-check-examples-typecheck' "$workflow"
require 'pkfire-cache:' "$workflow"
require 'fetch-depth: 0' "$workflow"
require 'bash tests/gates/bootstrap/preflight.sh' "$bootstrap"

reject_compiler_gate_block 'fetch-depth: 0'
reject_compiler_gate_block 'check_examples_typecheck.sh'
reject_compiler_gate_block 'lint_review_regressions.sh'
reject_compiler_gate_block 'check_playground_presets.sh'
reject_compiler_gate_block 'doctest_extract_run.sh'
require 'COMPILER_GATE_SKIP_STAGE2_ORACLES: "1"' "$workflow"
require_job_block compiler-stage2-oracles "wasmtime: 'true'"
require_job_block compiler-docs "wasmtime: 'true'"
require_job_block compiler-playground "wasmtime: 'true'"
require_job_block compiler-examples "wasmtime: 'true'"
require_job_block review-regressions "wasmtime: 'true'"

require 'path: ~/.cache/pkfire-mbt' '.github/actions/setup-vibe/action.yml'
require 'github.job' '.github/actions/setup-vibe/action.yml'

require_stage2_builder_wasmtime() {
  local job="$1"
  local block
  block="$(sed -n "/^  ${job}:/,/^  [a-zA-Z0-9_-]*:/p" "$workflow")"
  if ! grep -qF 'uses: ./.github/actions/setup-vibe' <<<"$block" ||
    ! grep -qF "wasmtime: 'true'" <<<"$block"; then
    echo "[ci-compiler-gate-layout] ${job} builds stage2 without shared wasmtime setup" >&2
    exit 1
  fi
  local setup_line
  local build_line
  setup_line="$(grep -nF 'uses: ./.github/actions/setup-vibe' <<<"$block" | head -1 | cut -d: -f1)"
  build_line="$(grep -nF 'scripts/generations.sh build' <<<"$block" | head -1 | cut -d: -f1)"
  if [ -z "$build_line" ] || [ "$setup_line" -ge "$build_line" ]; then
    echo "[ci-compiler-gate-layout] ${job} must set up wasmtime before its stage2 build" >&2
    exit 1
  fi
}

require_stage2_builder_wasmtime compiler-stage2-oracles
require_stage2_builder_wasmtime compiler-docs
require_stage2_builder_wasmtime compiler-playground
require_stage2_builder_wasmtime compiler-examples
require_stage2_builder_wasmtime review-regressions

echo "[ci-compiler-gate-layout] ok"
