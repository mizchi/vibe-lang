#!/usr/bin/env bash
# `vibe check --prove` gate (#3717, ADR-0121). Runs the prover over the
# fixtures in fixtures/prove/ against the given compiler and an external z3,
# and compares each report with the one pinned below:
#
#   proved.vibe       every obligation proved -> no output, exit 0
#   unproved.vibe     a false ensures, an Int overflow, a callee's unmet
#                     requires -> one line each with a counterexample, exit 1
#   unsupported.vibe  constructs outside the fragment are reported, exit 1
#   unknown.vibe      a timeout is `unknown`, which fails, exit 1
#
# Counterexample VALUES are masked: they are whatever model the solver picks,
# and a different z3 may pick another. That one exists is still checked.
#
# Usage: bash scripts/check_prove.sh <stage2.wasm>
# VIBE_PROVE_FIXTURES overrides the fixture directory (the self-test runs the
# gate over mutated copies). z3 must be on PATH: a missing solver FAILS the
# gate rather than skipping it, because an unrun prover proves nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

cli="${1:-${VIBE_STAGE2_WASM:-}}"
[ -n "$cli" ] && [ -s "$cli" ] || { echo "usage: check_prove.sh <stage2.wasm> (or set VIBE_STAGE2_WASM)" >&2; exit 2; }
runner="${VIBE_PROVE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$runner" ] || { echo "[prove] FAIL: native runner not built: $runner (bash scripts/ensure_viberun.sh)" >&2; exit 2; }
command -v z3 >/dev/null 2>&1 || { echo "[prove] FAIL: z3 is not on PATH; this gate runs the solver and does not skip without it" >&2; exit 2; }
dir="${VIBE_PROVE_FIXTURES:-fixtures/prove}"

fail=0
run_case() {
  local name="$1" want_code="$2" want="$3"
  local out code
  set +e
  out="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove "$dir/$name.vibe" 2>&1)"
  code=$?
  set -e
  local got
  got="$(printf '%s\n' "$out" | sed -E 's/-- counterexample: .*/-- counterexample: <model>/')"
  if [ "$code" != "$want_code" ] || [ "$got" != "$want" ]; then
    echo "[prove] FAIL: $name.vibe: exit $code (want $want_code)" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    fail=1
  fi
}

run_case proved 0 ""
run_case unproved 1 "$dir/unproved.vibe:5:1: unproved: ensures (result > x) of \`dec\` -- counterexample: <model>
$dir/unproved.vibe:12:5: unproved: overflow in (x + 1) in \`inc\` -- counterexample: <model>
$dir/unproved.vibe:21:3: unproved: requires of half: (x >= 0), called in \`call_half\` -- counterexample: <model>"
run_case unsupported 1 "$dir/unsupported.vibe:4:1: unsupported: \`let mut\` is outside the provable fragment (in \`sum_to\`)
$dir/unsupported.vibe:14:1: unsupported: parameter \`xs\` is not \`Int\` or \`Bool\` (in \`first\`)"
run_case unknown 1 "$dir/unknown.vibe:5:1: unknown: ensures result of \`fermat3\` -- z3 timed out (timeout 5000 ms)"

[ "$fail" = 0 ] || exit 1
echo "[prove] ok (proved silent, unproved with counterexamples, unsupported reported, a timeout fails)"
