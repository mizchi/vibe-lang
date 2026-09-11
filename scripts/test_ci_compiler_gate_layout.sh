#!/usr/bin/env bash
set -euo pipefail

# Overridable so the committed self-test can point this at a MUTATED copy and
# prove the guards can fail. Without that, the only thing CI ever asks is "does
# the valid workflow pass?", which stays green when the extraction breaks --
# the shape #2248 is in CLAUDE.md to prevent.
workflow="${VIBE_CI_LAYOUT_WORKFLOW:-.github/workflows/ci.yml}"
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
# ASK THE YAML WHICH JOBS DEPEND ON compiler-build (Codex review of #2648).
#
# This used to test `^    needs:.*compiler-build`, which only sees the flow
# form. The block form is equally valid and equally binding:
#
#     needs:
#       - compiler-build
#
# and the regex does not match it, so a routine reformat could restore the
# serialization regression with this gate still printing ok -- verified, it
# did. That is the same mistake scripts/check_pkfire_pin.sh took four rounds
# to stop making: a lexical approximation of a structural question. One round
# is enough here.
#
# PyYAML is provisioned in the structural-lint job, which is where this gate
# runs, and a missing parser is fatal rather than a pass.
deps="$(python3 - "$workflow" <<'PYEOF' || echo "__PYFAIL__"
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write(
        "[ci-compiler-gate-layout] FAIL: PyYAML is required to read the job graph.\n"
        "  Install it with: python3 -m pip install pyyaml\n"
    )
    sys.exit(1)

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

for job_id, job in (doc.get("jobs") or {}).items():
    if not isinstance(job, dict):
        continue
    needs = job.get("needs")
    if needs is None:
        needs = []
    elif isinstance(needs, str):          # `needs: compiler-build`
        needs = [needs]
    uses = any(
        isinstance(step, dict)
        and str(step.get("uses", "")).strip() == "./.github/actions/use-compiler-build"
        for step in (job.get("steps") or [])
    )
    print(f"{job_id}\t{'yes' if 'compiler-build' in needs else 'no'}\t{'yes' if uses else 'no'}")
PYEOF
)"
if [ "$deps" = "__PYFAIL__" ]; then
  echo "[ci-compiler-gate-layout] FAIL: could not read the job graph (see above)" >&2
  exit 1
fi

# THE COMPILER IS BUILT ONCE (#2645). A job that consumes it must say so, or
# actions/download-artifact races the producer and fails on a run where the
# scheduler happens to start them together. `needs:` is the only thing that
# orders them, so the two halves are required together: a job carrying the
# composite action must declare the dependency, and a job declaring the
# dependency must actually use the action.
if ! awk -F'\t' '$3=="yes"{found=1} END{exit !found}' <<<"$deps"; then
  echo "[ci-compiler-gate-layout] no job uses ./.github/actions/use-compiler-build" >&2
  echo "  The shared compiler build is how every gate job gets a stage2." >&2
  exit 1
fi
while IFS="$(printf '\t')" read -r job needs_shared uses_shared; do
  [ -n "${job:-}" ] || continue
  if [ "$uses_shared" = yes ] && [ "$needs_shared" = no ]; then
    echo "[ci-compiler-gate-layout] ${job} downloads the shared compiler build without 'needs: [compiler-build]'" >&2
    echo "  Add it to the job -- download-artifact cannot wait on its own." >&2
    exit 1
  fi
  if [ "$needs_shared" = yes ] && [ "$uses_shared" = no ] && [ "$job" != "ci-required" ]; then
    echo "[ci-compiler-gate-layout] ${job} declares 'needs: [compiler-build]' but never uses it" >&2
    echo "  Either add '- uses: ./.github/actions/use-compiler-build' or drop the dependency;" >&2
    echo "  waiting ~200s for an artifact the job ignores is pure latency." >&2
    exit 1
  fi
done <<EOF
$deps
EOF

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
lanes_needs="$(awk -F'\t' '$1=="compiler-gate-lanes"{print $2}' <<<"$deps")"
if [ -z "$lanes_needs" ]; then
  echo "[ci-compiler-gate-layout] FAIL: compiler-gate-lanes is not in the job graph" >&2
  exit 1
fi
if [ "$lanes_needs" = yes ]; then
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

# A GATE THAT PARSES YAML MUST HAVE ITS PARSER INSTALLED FIRST.
#
# Twice this session the same shape: the dependency was in the right JOB and
# not in the right ORDER. check_ci_seed_cache.sh exists because of it for the
# seed; this is the same bug for PyYAML. The layout gate ran at step 8 while
# the provisioning step sat at 18, so on a runner without a preinstalled
# PyYAML the required structural-lint job died before installing its own
# declared dependency -- and "the hosted image happens to ship it" is exactly
# the assumption #2252 forbids.
#
# Presence is not order, so this checks order.
if ! python3 - "$workflow" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write("[ci-compiler-gate-layout] FAIL: PyYAML is required to read the job graph.\n")
    sys.exit(1)

PARSING_GATES = ("test_ci_compiler_gate_layout.sh", "test_ci_compiler_gate_layout_test.sh",
                 "check_pkfire_pin.sh", "check_pkfire_pin_test.sh")

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

rc = 0
for job_id, job in (doc.get("jobs") or {}).items():
    if not isinstance(job, dict):
        continue
    steps = job.get("steps") or []
    provision = None
    for n, step in enumerate(steps):
        if isinstance(step, dict) and "pyyaml" in str(step.get("run", "")).lower():
            provision = n
            break
    for n, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        run = str(step.get("run", ""))
        gate = next((g for g in PARSING_GATES if g in run), None)
        if gate is None:
            continue
        if provision is None:
            print(f"[ci-compiler-gate-layout] {job_id} runs {gate} but never provisions PyYAML",
                  file=sys.stderr)
            rc = 1
        elif provision > n:
            print(f"[ci-compiler-gate-layout] {job_id} runs {gate} at step {n} but provisions "
                  f"PyYAML at step {provision} -- the gate dies before its dependency is installed",
                  file=sys.stderr)
            rc = 1
sys.exit(rc)
PYEOF
then
  echo "  Move the PyYAML step ahead of every gate that parses the workflows." >&2
  exit 1
fi

echo "[ci-compiler-gate-layout] ok"
