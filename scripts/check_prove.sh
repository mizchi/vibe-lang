#!/usr/bin/env bash
# `vibe check --prove` gate (#3717, #3719, ADR-0121). Runs the prover over
# the fixtures in fixtures/prove/ against the given compiler and one solver
# lane, and compares each report with the one pinned below:
#
#   VIBE_PROVE_SOLVER=z3    (the default) an external `z3` on PATH,
#                           `--solver=z3`, 5 s per query;
#   VIBE_PROVE_SOLVER=wasm  z3_wasi.wasm in the prover's own process,
#                           `--solver=wasm` (lib/@vibex/z3_wasi, built by
#                           scripts/build_z3_wasi.sh), bounded by `rlimit`.
#
# CI runs the z3 lane in `compiler-examples` and the wasm lane in `prove-wasm`
# (.github/workflows/ci.yml), which builds z3_wasi.wasm or restores it.
#
# The two lanes pin the SAME report for every fixture except unknown.vibe,
# whose line names the bound the solver ran under: both lanes print through
# one `prove_report_line`, and must agree on every verdict.
#
#   proved.vibe       every obligation proved -> no output, exit 0
#   datatypes.vibe    structs / enums as SMT datatypes and `match` as a case
#                     split, every obligation proved -> no output, exit 0
#   ranges.vibe       `Int::range_all` / `Int::range_any` imported from
#                     `@vibe/builtin` as quantifiers over an index range:
#                     three proved, two unproved, exit 1
#   unproved.vibe     a false ensures, an Int overflow, a callee's unmet
#                     requires, a parameter the body shadows, a branch-local
#                     `let`, `for` / `loop` contracts that do not hold ->
#                     one line each with a counterexample, exit 1
#   unsupported.vibe  constructs outside the fragment, a call to a function
#                     with no contract, an array write another name could
#                     see, a recursive cycle, and an `Array::all` /
#                     `Array::any` predicate the prover cannot quantify,
#                     are reported, exit 1
#   unknown.vibe      the solver running out of time is `unknown`, which
#                     fails, exit 1
#
# Counterexample VALUES are masked: they are whatever model the solver picks,
# and a different z3 may pick another. That one exists is still checked.
#
# Usage: [VIBE_PROVE_SOLVER=z3|wasm] bash scripts/check_prove.sh <stage2.wasm>
# VIBE_PROVE_FIXTURES overrides the fixture directory (the self-test runs the
# gate over mutated copies). The lane's solver must be present -- z3 on PATH,
# or lib/@vibex/z3_wasi/z3_wasi.wasm built: a missing solver FAILS the gate
# rather than skipping it, because an unrun prover proves nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

cli="${1:-${VIBE_STAGE2_WASM:-}}"
[ -n "$cli" ] && [ -s "$cli" ] || { echo "usage: check_prove.sh <stage2.wasm> (or set VIBE_STAGE2_WASM)" >&2; exit 2; }
runner="${VIBE_PROVE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$runner" ] || { echo "[prove] FAIL: native runner not built: $runner (bash scripts/ensure_viberun.sh)" >&2; exit 2; }
solver="${VIBE_PROVE_SOLVER:-z3}"
case "$solver" in
  z3)
    command -v z3 >/dev/null 2>&1 || { echo "[prove] FAIL: z3 is not on PATH; this gate runs the solver and does not skip without it" >&2; exit 2; }
    unknown_detail="z3 timed out (5000 ms limit)" ;;
  wasm)
    [ -s lib/@vibex/z3_wasi/z3_wasi.wasm ] || { echo "[prove] FAIL: lib/@vibex/z3_wasi/z3_wasi.wasm is not built (bash scripts/build_z3_wasi.sh); this gate runs the solver and does not skip without it" >&2; exit 2; }
    unknown_detail="z3 returned unknown (rlimit 20000000)" ;;
  *) echo "usage: VIBE_PROVE_SOLVER must be z3 or wasm, not '$solver'" >&2; exit 2 ;;
esac
dir="${VIBE_PROVE_FIXTURES:-fixtures/prove}"

fail=0
run_case() {
  local name="$1" want_code="$2" want="$3"
  local out code
  set +e
  out="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove --solver="$solver" "$dir/$name.vibe" 2>&1)"
  code=$?
  set -e
  local got
  got="$(printf '%s\n' "$out" | sed -E 's/-- counterexample: .*/-- counterexample: <model>/')"
  if [ "$code" != "$want_code" ] || [ "$got" != "$want" ]; then
    echo "[prove] FAIL ($solver): $name.vibe: exit $code (want $want_code)" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    fail=1
  fi
}

run_case proved 0 ""
run_case datatypes 0 ""
run_case ranges 1 "$dir/ranges.vibe:32:62: unproved: the index of xs[(i + 1)] is within the array, in \`off_by_one\` -- counterexample: <model>
$dir/ranges.vibe:38:12: unproved: ensures (result > 0) of \`any_not_first\` -- counterexample: <model>"
run_case unproved 1 "$dir/unproved.vibe:5:57: unproved: ensures (result > x) of \`dec\` -- counterexample: <model>
$dir/unproved.vibe:12:5: unproved: overflow in (x + 1) in \`inc\` -- counterexample: <model>
$dir/unproved.vibe:21:3: unproved: requires of half: (x >= 0), called in \`call_half\` -- counterexample: <model>
$dir/unproved.vibe:26:45: unproved: ensures (result == x) of \`shadowed\` -- counterexample: <model>
$dir/unproved.vibe:33:49: unproved: ensures (result == 0) of \`branch_scope\` -- counterexample: <model>
$dir/unproved.vibe:49:48: unproved: ensures (result > 0) of \`coin_value\` -- counterexample: <model>
$dir/unproved.vibe:59:9: unproved: a \`match\` on x covers every value, in \`uncovered\` -- counterexample: <model>
$dir/unproved.vibe:67:5: unproved: the divisor of (x / d) is not zero, in \`ratio\` -- counterexample: <model>
$dir/unproved.vibe:67:5: unproved: overflow in (x / d) in \`ratio\` -- counterexample: <model>
$dir/unproved.vibe:77:67: unproved: ensures (result == 0) of \`field_branch\` -- counterexample: <model>
$dir/unproved.vibe:93:69: unproved: ensures (result == 0) of \`pattern_branch\` -- counterexample: <model>
$dir/unproved.vibe:105:5: unproved: overflow in (x << 1) in \`doubled\` -- counterexample: <model>
$dir/unproved.vibe:112:18: unproved: invariant ((0 <= i) && (i <= 10)) holds again after each iteration, in \`count_up\` -- counterexample: <model>
$dir/unproved.vibe:125:16: unproved: the measure n stays non-negative and drops on each iteration, in \`stuck\` -- counterexample: <model>
$dir/unproved.vibe:134:64: unproved: ensures (result == 0) of \`cond_step\` -- counterexample: <model>
$dir/unproved.vibe:150:5: unproved: the index of xs[1] is within the array, in \`second\` -- counterexample: <model>
$dir/unproved.vibe:154:3: unproved: the index of Array::get(xs, at=i) is within the array, in \`get_at\` -- counterexample: <model>
$dir/unproved.vibe:162:16: unproved: the measure (n - i) stays non-negative and drops on each iteration, in \`stall\` -- counterexample: <model>
$dir/unproved.vibe:177:34: unproved: invariant (last >= 0) holds again after each iteration, in \`last_of\` -- counterexample: <model>
$dir/unproved.vibe:184:50: unproved: ensures (result == 0) of \`plain\` -- counterexample: <model>
$dir/unproved.vibe:195:53: unproved: the measure f stays non-negative and drops on each iteration, in \`idle\` -- counterexample: <model>
$dir/unproved.vibe:213:57: unproved: the measure k is not negative when the loop starts, in \`wander\` -- counterexample: <model>
$dir/unproved.vibe:225:5: unproved: the index of xs[2] is within the array, in \`past_end\` -- counterexample: <model>
$dir/unproved.vibe:230:42: unproved: ensures (result == 1) of \`overwritten\` -- counterexample: <model>
$dir/unproved.vibe:237:77: unproved: ensures (result == 0) of \`length_kept\` -- counterexample: <model>
$dir/unproved.vibe:248:43: unproved: ensures (result == 0) of \`nested_write\` -- counterexample: <model>
$dir/unproved.vibe:258:53: unproved: ensures (result == 0) of \`read_after_index_write\` -- counterexample: <model>
$dir/unproved.vibe:267:50: unproved: ensures (result > x) of \`word_next\` -- counterexample: <model>
$dir/unproved.vibe:272:53: unproved: ensures (result > 0) of \`word_local_wraps\` -- counterexample: <model>
$dir/unproved.vibe:278:5: unproved: the divisor of (x / d) is not zero, in \`word_udiv\` -- counterexample: <model>
$dir/unproved.vibe:282:58: unproved: ensures result of \`word_unsigned_low\` -- counterexample: <model>
$dir/unproved.vibe:288:72: unproved: ensures result of \`word_join\` -- counterexample: <model>
$dir/unproved.vibe:298:58: unproved: ensures Array::all(xs, f=(x) -> { (x >= 0) }) of \`claims_nonneg\` -- counterexample: <model>
$dir/unproved.vibe:305:12: unproved: ensures (result >= 0) of \`any_is_not_first\` -- counterexample: <model>
$dir/unproved.vibe:312:31: unproved: overflow in (x + 1) in \`succ_any\` -- counterexample: <model>
$dir/unproved.vibe:317:53: unproved: ensures (result > 0) of \`boxed_positive\` -- counterexample: <model>
$dir/unproved.vibe:327:18: unproved: invariant ((((0 <= i) && (i <= n)) && (Array::length(xs) == i)) && Array::all(xs, f=(x) -> { (x == 0) })) holds again after each iteration, in \`not_all_zero\` -- counterexample: <model>"
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
$dir/unsupported.vibe:109:1: unsupported: \`xs\` is written, and is also used as a value: a written array is named only as the array of \`Array::get\`, \`Array::length\`, \`xs[i]\`, \`Array::set\`, \`Array::push\`, \`Array::all\` or \`Array::any\` (in \`aliased\`)
$dir/unsupported.vibe:117:1: unsupported: \`xs\` is written, and is also used as a value: a written array is named only as the array of \`Array::get\`, \`Array::length\`, \`xs[i]\`, \`Array::set\`, \`Array::push\`, \`Array::all\` or \`Array::any\` (in \`iterated\`)
$dir/unsupported.vibe:126:1: unsupported: a write to \`xs\`, which is not bound exactly once, by \`let\`, to an array literal (in \`rebound\`)
$dir/unsupported.vibe:135:9: unsupported: \`Int::to_int32\` answers an \`Option\`, which is not modelled; test the range and use \`Int::wrap_int32\` (in \`checked_word\`)
$dir/unsupported.vibe:147:3: unsupported: \`Array::all\`'s predicate must be a lambda written at the call (in \`named_pred\`)
$dir/unsupported.vibe:152:3: unsupported: a call inside \`Array::all\`'s predicate: its result would be one value for every element (in \`called_pred\`)
$dir/unsupported.vibe:158:11: unsupported: \`Array::all\`'s predicate assigns \`n\` (in \`counting_pred\`)"
run_case unknown 1 "$dir/unknown.vibe:9:12: unknown: ensures result of \`fermat3\` -- $unknown_detail"

# A counterexample is spelled as the program would write the arguments: an
# `Array[Int]` as a literal and a struct with its field names, never the
# solver's own terms (`(|Array[Int]::mk| ((as const ..)) ..)`), so it can be
# pasted into a call. The values are the solver's choice; the spelling is not.
spelled_case() {
  local name="$1"
  local out
  set +e
  out="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove --solver="$solver" "$dir/$name.vibe" 2>&1)"
  set -e
  local raw
  raw="$(printf '%s\n' "$out" | sed -n 's/.*-- counterexample: //p' | grep -E '[|]|\(as |lambda|store' || true)"
  if [ -n "$raw" ]; then
    echo "[prove] FAIL ($solver): $name.vibe: a counterexample keeps the solver's terms:" >&2
    printf '%s\n' "$raw" >&2
    fail=1
  fi
  local want
  for want in '`second` -- counterexample: xs = [' '`boxed_positive` -- counterexample: b = Boxed::{ n: '; do
    if ! printf '%s\n' "$out" | grep -qF -- "$want"; then
      echo "[prove] FAIL ($solver): $name.vibe: no counterexample spelled '$want...'" >&2
      fail=1
    fi
  done
}

spelled_case unproved

# #3717: each counterexample is replayed against the runtime contract checks.
# For every unproved obligation the runtime also checks -- an ensures, a
# callee's requires, an index, a divisor, a `match`'s coverage, a loop's
# invariant or measure -- the call the counterexample names is made in a
# `test` block of a copy of the fixture, and it must TRAP with that function
# on the stack. A counterexample that runs clean means the prover's model of
# the program and the program disagree. `overflow` obligations are not
# replayed: an `Int` wraps at run time (#1877), it does not exit. Nor is a
# counterexample whose array is longer than the elements the model shows
# (`[a, ..., ...] (length N)`): it is named in a note instead.
#
# A counterexample can be spurious by design, where the prover deliberately
# knows less than the run does. Those are named here, and each must keep
# running clean -- a listed one that starts trapping fails too, so the list
# cannot go stale:
#   plain   a loop-assigned local with no invariant is forgotten after the
#           loop, so `ensures: result == 0` is unproved though it holds.
replay_spurious="plain"
replay_case() {
  local name="$1"
  local work="_build/prove_replay.$$.$name"
  rm -rf "$work"
  mkdir -p "$work"
  set +e
  VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove --solver="$solver" --json "$dir/$name.vibe" > "$work/report.json" 2>&1
  set -e
  if ! node -e '
    const fs = require("fs");
    const [fixture, report, work] = process.argv.slice(1);
    const src = fs.readFileSync(fixture, "utf8");
    const MIN = "-4611686018427387904";
    const split = (s) => {
      const out = []; let depth = 0, cur = "";
      for (const c of s) {
        if ("([{".includes(c)) depth++;
        if (")]}".includes(c)) depth--;
        if (c === "," && depth === 0) { out.push(cur.trim()); cur = ""; } else cur += c;
      }
      if (cur.trim() !== "") out.push(cur.trim());
      return out;
    };
    const rows = [];
    const partial = [];
    for (const d of JSON.parse(fs.readFileSync(report, "utf8"))) {
      const m = d.message.match(/^unproved: (.*) `([A-Za-z_0-9]+)` -- counterexample: (.*)$/);
      if (!m || m[1].startsWith("overflow in")) continue;
      // An array longer than the elements the model was asked for prints as
      // `[a, b, ..., ...] (length N)`: a true counterexample, but not a value
      // a call can be written with. It is named, not replayed.
      if (/, \.\.\.\] \(length /.test(m[3])) { partial.push(m[2]); continue; }
      const args = m[3].startsWith("none needed") ? [] : split(m[3]).map((p) => {
        const eq = p.indexOf(" = ");
        // The least `Int` has no literal: its magnitude is one past the bound.
        return `${p.slice(0, eq)} = ${p.slice(eq + 3).split(MIN).join("(-4611686018427387903 - 1)")}`;
      });
      const file = `${work}/r${rows.length}_${m[2]}_test.vibe`;
      const call = `${m[2]}(${args.join(", ")})`;
      fs.writeFileSync(file, `${src}\n// replay of: ${d.message}\ntest "replay" {\n  let _ = ${call}\n}\n`);
      rows.push(`${file}\t${m[2]}\t${call}`);
    }
    fs.writeFileSync(`${work}/plan.tsv`, rows.join("\n") + "\n");
    fs.writeFileSync(`${work}/partial.txt`, partial.join(" "));
    if (rows.length === 0) { console.error("no counterexample to replay"); process.exit(1); }
  ' "$dir/$name.vibe" "$work/report.json" "$work"; then
    echo "[prove] FAIL ($solver): $name.vibe: could not plan the counterexample replay" >&2
    fail=1
    return
  fi
  set +e
  # One file at a time: the verdicts are read back per file from one log, so
  # nothing may run beside a replay and write into it.
  VIBE_TEST_JOBS=1 VIBE_TEST_CLI_WASM="$cli" VIBE_TEST_QUIET_COMPILER_NOTE=1 bash scripts/vibe_test.sh "$work"/*_test.vibe > "$work/run.log" 2>&1
  set -e
  if ! node -e '
    const fs = require("fs");
    const [work, spurious, name, partialText] = process.argv.slice(1);
    const partial = (partialText || "").split(" ").filter((s) => s !== "");
    const listed = spurious.split(" ").filter((s) => s !== "");
    // vibe_test.sh reports each file as `ok   PATH`, `FAIL PATH` or
    // `FAIL (compile) PATH`, followed by its indented detail lines. A block
    // runs to the next file header or the closing `[vibe-test]` summary; a
    // blank line inside it does not end it. `raw` keeps the block as printed,
    // so a verdict this cannot read is shown rather than summarized.
    const blocks = new Map();
    let cur = null;
    for (const line of fs.readFileSync(`${work}/run.log`, "utf8").split("\n")) {
      const m = line.match(/^(ok|FAIL \(compile\)|FAIL) +(\S+)/);
      if (m) { cur = { verdict: m[1], detail: [], raw: [line] }; blocks.set(m[2], cur); }
      else if (line.startsWith("[vibe-test]")) cur = null;
      else if (cur) { cur.raw.push(line); if (line.trim() !== "") cur.detail.push(line.trim()); }
    }
    const errs = [];
    const seen = new Set();
    for (const row of fs.readFileSync(`${work}/plan.tsv`, "utf8").split("\n").filter((l) => l !== "")) {
      const [file, fn, call] = row.split("\t");
      seen.add(fn);
      const b = blocks.get(file);
      if (!b) { errs.push(`replay of \`${fn}\` has no verdict: ${call}`); continue; }
      if (b.verdict === "FAIL (compile)") { errs.push(`replay of \`${fn}\` does not compile: ${call} -- ${b.detail.join(" / ")}`); continue; }
      const trapped = b.verdict === "FAIL" && b.detail.some((l) => l.startsWith("trap:")) && b.detail.some((l) => l === `at ${fn}` || l.startsWith(`at ${fn} (`) || l.startsWith(`at ${fn}__`));
      if (listed.includes(fn)) {
        if (b.verdict !== "ok") errs.push(`replay of \`${fn}\` is listed as spurious but no longer runs clean: ${call} -- drop it from replay_spurious`);
      } else if (!trapped) {
        errs.push(`replay of \`${fn}\` does not trap in \`${fn}\` at run time: ${call} (${b.verdict}${b.detail.length ? ": " + b.detail.join(" / ") : ", with no report: the runner printed " + JSON.stringify(b.raw.join("\n"))})`);
      }
    }
    for (const fn of partial) seen.add(fn);
    for (const fn of listed) if (name === "unproved" && !seen.has(fn)) errs.push(`\`${fn}\` is listed as spurious but has no counterexample to replay`);
    if (errs.length) { for (const e of errs) console.error(e); process.exit(1); }
  ' "$work" "$replay_spurious" "$name" "$(cat "$work/partial.txt")" 2> "$work/judge.err"; then
    sed "s|^|[prove] FAIL ($solver): $name.vibe: |" "$work/judge.err" >&2
    fail=1
  fi
  # One note per function, so a reader (and the self-test) can match a name
  # whatever else the solver's models happened to truncate.
  local skipped
  for skipped in $(cat "$work/partial.txt"); do
    echo "[prove] note ($solver): $name.vibe: not replayed, an array longer than the model shows: $skipped" >&2
  done
  rm -rf "$work"
}

replay_case unproved
replay_case ranges

# `--json` reports the same diagnostics as the text: one LSP Diagnostic per
# line, at that line's position, with that line's message, and `[]` for a
# file that proves.
json_case() {
  local name="$1"
  local text json
  set +e
  text="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove --solver="$solver" "$dir/$name.vibe" 2>&1)"
  json="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check --prove --solver="$solver" --json "$dir/$name.vibe" 2>&1)"
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

# A solver the CLI does not know, and `--solver` without `--prove`, are
# refused with the edit, never read as a path or ignored.
refusal_case() {
  local want="$1"; shift
  local out code
  set +e
  out="$(VIBE_RUNNER="$runner" VIBE_CLI_WASM="$cli" bash runtime/vibe check "$@" 2>&1)"
  code=$?
  set -e
  if [ "$code" = 0 ] || ! printf '%s\n' "$out" | grep -qF -- "$want"; then
    echo "[prove] FAIL: \`vibe check $*\` exited $code without saying: $want" >&2
    printf '%s\n' "$out" >&2
    fail=1
  fi
}
refusal_case "is not a solver; use \`--solver=z3\`" --prove --solver=cvc5 "$dir/proved.vibe"
refusal_case "\`--solver\` chooses the solver of \`--prove\`" --solver="$solver" "$dir/proved.vibe"

[ "$fail" = 0 ] || exit 1
echo "[prove] ok ($solver: proved silent, unproved with counterexamples in program spelling that trap when replayed, unsupported reported, an unknown answer fails, --json carries the same diagnostics, a bad --solver is refused)"
