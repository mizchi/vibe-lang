#!/usr/bin/env bash
# `vibe check --prove` gate (#3717, ADR-0121). Runs the prover over the
# fixtures in fixtures/prove/ against the given compiler and an external z3,
# and compares each report with the one pinned below:
#
#   proved.vibe       every obligation proved -> no output, exit 0
#   datatypes.vibe    structs / enums as SMT datatypes and `match` as a case
#                     split, every obligation proved -> no output, exit 0
#   unproved.vibe     a false ensures, an Int overflow, a callee's unmet
#                     requires, a parameter the body shadows, a branch-local
#                     `let`, `for` / `loop` contracts that do not hold ->
#                     one line each with a counterexample, exit 1
#   unsupported.vibe  constructs outside the fragment, a call to a function
#                     with no contract, an array write another name could
#                     see, and a recursive
#                     cycle, are reported, exit 1
#   unknown.vibe      the solver running out of time is `unknown`, which
#                     fails, exit 1
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
run_case datatypes 0 ""
run_case unproved 1 "$dir/unproved.vibe:5:1: unproved: ensures (result > x) of \`dec\` -- counterexample: <model>
$dir/unproved.vibe:12:5: unproved: overflow in (x + 1) in \`inc\` -- counterexample: <model>
$dir/unproved.vibe:21:3: unproved: requires of half: (x >= 0), called in \`call_half\` -- counterexample: <model>
$dir/unproved.vibe:26:1: unproved: ensures (result == x) of \`shadowed\` -- counterexample: <model>
$dir/unproved.vibe:33:1: unproved: ensures (result == 0) of \`branch_scope\` -- counterexample: <model>
$dir/unproved.vibe:49:1: unproved: ensures (result > 0) of \`coin_value\` -- counterexample: <model>
$dir/unproved.vibe:59:9: unproved: a \`match\` on x covers every value, in \`uncovered\` -- counterexample: <model>
$dir/unproved.vibe:67:5: unproved: the divisor of (x / d) is not zero, in \`ratio\` -- counterexample: <model>
$dir/unproved.vibe:67:5: unproved: overflow in (x / d) in \`ratio\` -- counterexample: <model>
$dir/unproved.vibe:77:1: unproved: ensures (result == 0) of \`field_branch\` -- counterexample: <model>
$dir/unproved.vibe:93:1: unproved: ensures (result == 0) of \`pattern_branch\` -- counterexample: <model>
$dir/unproved.vibe:105:5: unproved: overflow in (x << 1) in \`doubled\` -- counterexample: <model>
$dir/unproved.vibe:112:18: unproved: invariant ((0 <= i) && (i <= 10)) holds again after each iteration, in \`count_up\` -- counterexample: <model>
$dir/unproved.vibe:125:16: unproved: the measure n stays non-negative and drops on each iteration, in \`stuck\` -- counterexample: <model>
$dir/unproved.vibe:134:1: unproved: ensures (result == 0) of \`cond_step\` -- counterexample: <model>
$dir/unproved.vibe:150:5: unproved: the index of xs[1] is within the array, in \`second\` -- counterexample: <model>
$dir/unproved.vibe:154:3: unproved: the index of Array::get(xs, at=i) is within the array, in \`get_at\` -- counterexample: <model>
$dir/unproved.vibe:162:16: unproved: the measure (n - i) stays non-negative and drops on each iteration, in \`stall\` -- counterexample: <model>
$dir/unproved.vibe:177:34: unproved: invariant (last >= 0) holds again after each iteration, in \`last_of\` -- counterexample: <model>
$dir/unproved.vibe:184:1: unproved: ensures (result == 0) of \`plain\` -- counterexample: <model>
$dir/unproved.vibe:195:53: unproved: the measure f stays non-negative and drops on each iteration, in \`idle\` -- counterexample: <model>
$dir/unproved.vibe:213:57: unproved: the measure k is not negative when the loop starts, in \`wander\` -- counterexample: <model>
$dir/unproved.vibe:225:5: unproved: the index of xs[2] is within the array, in \`past_end\` -- counterexample: <model>
$dir/unproved.vibe:230:1: unproved: ensures (result == 1) of \`overwritten\` -- counterexample: <model>
$dir/unproved.vibe:237:1: unproved: ensures (result == 0) of \`length_kept\` -- counterexample: <model>
$dir/unproved.vibe:248:1: unproved: ensures (result == 0) of \`nested_write\` -- counterexample: <model>
$dir/unproved.vibe:258:1: unproved: ensures (result == 0) of \`read_after_index_write\` -- counterexample: <model>"
run_case unsupported 1 "$dir/unsupported.vibe:7:9: unsupported: a \`while\` without a \`where { decreases: .. }\` measure: termination is not proved, so the result would be partial correctness only (in \`sum_to\`)
$dir/unsupported.vibe:14:1: unsupported: parameter \`xs\` is not \`Int\`, \`Bool\`, \`Array[Int]\`, or a struct / enum of this file (non-generic, every field \`Int\`, \`Bool\` or such a type) (in \`first\`)
$dir/unsupported.vibe:20:1: unsupported: \`ping\` is part of, or calls into, a recursive cycle: termination is not proved, so the result would be partial correctness only (in \`ping\`)
$dir/unsupported.vibe:24:1: unsupported: \`pong\` is part of, or calls into, a recursive cycle: termination is not proved, so the result would be partial correctness only (in \`pong\`)
$dir/unsupported.vibe:38:11: unsupported: \`spin\` has no \`where\` contract, so the call cannot be checked modularly; give it one (\`ensures: true\` at least), and its body is proved too (in \`calls_helper\`)
$dir/unsupported.vibe:47:1: unsupported: parameter \`h\` is not \`Int\`, \`Bool\`, \`Array[Int]\`, or a struct / enum of this file (non-generic, every field \`Int\`, \`Bool\` or such a type) (in \`held\`)
$dir/unsupported.vibe:62:5: unsupported: \`==\` on \`Odd\` calls a program-written \`equals\` (on that type or one it contains), which the prover does not read (in \`same\`)
$dir/unsupported.vibe:68:5: unsupported: \`<<\` by a count that is not a constant from 0 to 62 (in \`shift_by\`)
$dir/unsupported.vibe:73:1: unsupported: a contract clause that leaves the function with \`return\` (in \`leaves\`)
$dir/unsupported.vibe:88:5: unsupported: \`==\` on arrays: their contents past the length are not modelled, so equality is not encoded (in \`same_arrays\`)
$dir/unsupported.vibe:98:3: unsupported: \`Array::length\` has no \`where\` contract, so the call cannot be checked modularly; give it one (\`ensures: true\` at least), and its body is proved too (in \`own_length\`)
$dir/unsupported.vibe:103:1: unsupported: a write to the parameter \`xs\`, which its caller holds: only a local array is written (in \`param_write\`)
$dir/unsupported.vibe:109:1: unsupported: \`xs\` is written, and is also used as a value: a written array is named only as the array of \`Array::get\`, \`Array::length\`, \`xs[i]\`, \`Array::set\` or \`Array::push\` (in \`aliased\`)
$dir/unsupported.vibe:117:1: unsupported: \`xs\` is written, and is also used as a value: a written array is named only as the array of \`Array::get\`, \`Array::length\`, \`xs[i]\`, \`Array::set\` or \`Array::push\` (in \`iterated\`)
$dir/unsupported.vibe:126:1: unsupported: a write to \`xs\`, which is not bound exactly once, by \`let\`, to an array literal (in \`rebound\`)"
run_case unknown 1 "$dir/unknown.vibe:5:1: unknown: ensures result of \`fermat3\` -- z3 timed out (5000 ms limit)"

# `--json` reports the same diagnostics as the text: one LSP Diagnostic per
# line, at that line's position, with that line's message, and `[]` for a
# file that proves.
json_case() {
  local name="$1"
  local text json
  set +e
  text="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove "$dir/$name.vibe" 2>&1)"
  json="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove --json "$dir/$name.vibe" 2>&1)"
  set -e
  if ! node -e '
    const [path, text, json] = process.argv.slice(1);
    const want = text === "" ? [] : text.split("\n").map((l) => {
      const m = l.slice(path.length + 1).match(/^(\d+):(\d+): (.*)$/);
      return { line: Number(m[1]) - 1, character: Number(m[2]) - 1, message: m[3] };
    });
    const got = JSON.parse(json).map((d) => ({ line: d.range.start.line, character: d.range.start.character, message: d.message }));
    const norm = (xs) => JSON.stringify(xs.map((x) => ({ ...x, message: x.message.replace(/-- counterexample: .*/, "-- counterexample: <model>") })));
    if (norm(want) !== norm(got)) { console.error("text: " + norm(want) + "\njson: " + norm(got)); process.exit(1); }
  ' "$dir/$name.vibe" "$text" "$json"; then
    echo "[prove] FAIL: $name.vibe: --json does not carry the text report's diagnostics" >&2
    fail=1
  fi
}

json_case proved
json_case unproved
json_case unsupported

[ "$fail" = 0 ] || exit 1
echo "[prove] ok (proved silent, unproved with counterexamples, unsupported reported, an unknown answer fails, --json carries the same diagnostics)"
