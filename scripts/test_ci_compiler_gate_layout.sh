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
  if [ -z "$build_line" ] || [ -z "$setup_line" ] || [ "$setup_line" -ge "$build_line" ]; then
    echo "[ci-compiler-gate-layout] ${job} must set up wasmtime before its stage2 build" >&2
    exit 1
  fi
}

# #2184 belongs to whoever actually runs `generations.sh build`, and since
# #2645 that is one job: compiler-build. The five gate jobs that used to build
# their own stage2 now download the one it produces, so requiring a build step
# of them would pin the layout this change removed.
require_stage2_builder_wasmtime compiler-build

# THE COMPILER IS BUILT ONCE (#2645). A job that consumes it must say so, or
# actions/download-artifact races the producer and fails on a run where the
# scheduler happens to start them together. `needs:` is the only thing that
# orders them, so the two halves are required together: a job carrying the
# composite action must declare the dependency, and a job declaring the
# dependency must actually use the action.
consumers="$(grep -n 'uses: ./.github/actions/use-compiler-build' "$workflow" | cut -d: -f1)"
if [ -z "$consumers" ]; then
  echo "[ci-compiler-gate-layout] no job uses ./.github/actions/use-compiler-build" >&2
  echo "  The shared compiler build is how every gate job gets a stage2." >&2
  exit 1
fi
for job in $(awk '
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  /^[A-Za-z0-9_-]+:/ { if (!/^jobs:/) in_jobs = 0 }
  in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); print job }
' "$workflow"); do
  block="$(sed -n "/^  ${job}:\$/,/^  [a-zA-Z0-9_-]*:\$/p" "$workflow")"
  uses_shared=0
  needs_shared=0
  grep -qF 'uses: ./.github/actions/use-compiler-build' <<<"$block" && uses_shared=1
  grep -qE '^    needs:.*compiler-build' <<<"$block" && needs_shared=1
  if [ "$uses_shared" = 1 ] && [ "$needs_shared" = 0 ]; then
    echo "[ci-compiler-gate-layout] ${job} downloads the shared compiler build without 'needs: [compiler-build]'" >&2
    echo "  Add it to the job -- download-artifact cannot wait on its own." >&2
    exit 1
  fi
  if [ "$needs_shared" = 1 ] && [ "$uses_shared" = 0 ] && [ "$job" != "ci-required" ]; then
    echo "[ci-compiler-gate-layout] ${job} declares 'needs: [compiler-build]' but never uses it" >&2
    echo "  Either add '- uses: ./.github/actions/use-compiler-build' or drop the dependency;" >&2
    echo "  waiting ~200s for an artifact the job ignores is pure latency." >&2
    exit 1
  fi
done

# THE LANES MUST NOT WAIT FOR compiler-build.
#
# Measured on main, compiler-touching runs: the old layout (every job building
# in-job, starting at t=0) finished in 858s; the shared-build layout finished in
# 959s, because 30 jobs released in a burst behind this dependency reached only
# 11 concurrent against 18 before -- median job start 365s against 3s -- and
# compiler-gate (late) began at 489s and then ran 466s instead of 341s, having
# never warmed its own header cache.
#
# So compiler-gate-lanes builds in-job on purpose. Re-adding the dependency
# would restore that regression SILENTLY: CI would still be green, only slower,
# which is the kind of change nobody notices for weeks. The decision is pinned
# here rather than left in a comment.
lanes_block="$(sed -n '/^  compiler-gate-lanes:$/,/^  [a-zA-Z0-9_-]*:$/p' "$workflow")"
if [ -z "$lanes_block" ]; then
  echo "[ci-compiler-gate-layout] FAIL: no compiler-gate-lanes job found -- the scan did not run" >&2
  exit 1
fi
if grep -qE '^    needs:.*compiler-build' <<<"$lanes_block"; then
  echo "[ci-compiler-gate-layout] compiler-gate-lanes declares 'needs: [compiler-build]'" >&2
  echo "  The lanes build in-job on purpose: they are the critical path, and" >&2
  echo "  waiting for the shared build measured 959s against 858s on main" >&2
  echo "  (runs 34583809863 vs 34578957960). Drop the dependency." >&2
  exit 1
fi
# ...and it must still be the job that BUILDS, not one that silently stopped.
if ! grep -qF 'bash scripts/generations.sh build' <<<"$lanes_block"; then
  echo "[ci-compiler-gate-layout] compiler-gate-lanes no longer builds stage2 in-job" >&2
  echo "  Without the build the lanes run against no compiler at all, and the" >&2
  echo "  header cache they exist to warm stays cold." >&2
  exit 1
fi

echo "[ci-compiler-gate-layout] ok"
