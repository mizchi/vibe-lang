#!/usr/bin/env bash
# ADR-0120 Phase 2b (#3680): `vibe check --warn-missing-labels` end to end.
# The warnings are the label codemod's own edits: one row per label it would
# write, none once it has written them, none on a file with errors. They never
# change the exit status, and `--json` reports them the same way on both lanes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
compiler="${VIBE_TEST_CLI_WASM:?set VIBE_TEST_CLI_WASM to the current checkout stage2}"
mkdir -p "$ROOT_DIR/_build"
work="$(mktemp -d "$ROOT_DIR/_build/warn-labels.XXXXXX")"
trap 'rm -rf "$work"' EXIT
rel="${work#"$ROOT_DIR/"}"
fail() { echo "warn-missing-labels: $*" >&2; exit 1; }

invoke() {
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$compiler" "$@"
}

cat > "$rel/dep.vibe" <<'VIBE'
export fn sub(x: Int, y: Int) -> Int {
  x - y
}
VIBE
cat > "$rel/main.vibe" <<'VIBE'
import ./dep.vibe { sub }

export fn main() -> Int {
  sub(10, 3)
}
VIBE

# Without the flag nothing changes: clean, silent.
invoke check "$rel/main.vibe" > "$work/plain.out" 2> "$work/plain.err" || fail "a clean file failed without the flag"
[ ! -s "$work/plain.out" ] || fail "stdout is not empty without the flag"
if grep -q 'label this argument' "$work/plain.err"; then fail "a label warning without the flag"; fi

# With it, the import-resolved callee warns once per argument, on stderr, exit 0.
invoke check --warn-missing-labels "$rel/main.vibe" > "$work/warn.out" 2> "$work/warn.err" || fail "a warning changed the exit status"
[ ! -s "$work/warn.out" ] || fail "a warning reached stdout"
grep -Fq 'line 4:7-9: warning: label this argument: write `x = 10`' "$work/warn.err" || fail "no row for x = 10: $(cat "$work/warn.err")"
grep -Fq 'line 4:11-12: warning: label this argument: write `y = 3`' "$work/warn.err" || fail "no row for y = 3: $(cat "$work/warn.err")"
[ "$(grep -c 'label this argument' "$work/warn.err")" = 2 ] || fail "expected exactly two rows"

# JSON: severity-2 entries, exit 0.
invoke check --warn-missing-labels --json "$rel/main.vibe" > "$work/warn.json" || fail "a JSON warning changed the exit status"
[ "$(grep -o '"severity":2' "$work/warn.json" | wc -l | tr -d ' ')" = 2 ] || fail "JSON rows: $(cat "$work/warn.json")"

# Both lanes give the same JSON on a file with no imports.
cat > "$rel/solo.vibe" <<'VIBE'
fn sub(x: Int, y: Int) -> Int {
  x - y
}

export fn main() -> Int {
  sub(10, 3)
}
VIBE
invoke check --warn-missing-labels --json "$rel/solo.vibe" > "$work/solo.fs.json" || fail "FS lane JSON exit"
invoke check --single-file --warn-missing-labels --json "$rel/solo.vibe" > "$work/solo.sf.json" || fail "single-file JSON exit"
cmp "$work/solo.fs.json" "$work/solo.sf.json" || fail "the lanes disagree: $(cat "$work/solo.fs.json") vs $(cat "$work/solo.sf.json")"
grep -Fq 'write `x = 10`' "$work/solo.fs.json" || fail "solo JSON has no row"

# After the codemod has run, the flag reports nothing.
invoke refactor add-labels --write "$rel/main.vibe" > "$work/write.out"
invoke check --warn-missing-labels "$rel/main.vibe" > "$work/after.out" 2> "$work/after.err" || fail "the rewritten file failed"
if grep -q 'label this argument' "$work/after.err"; then fail "rows after the codemod: $(cat "$work/after.err")"; fi

# A file with errors reports its errors only.
printf 'fn sub(x: Int, y: Int) -> Int {\n  x - y\n}\n\nexport fn main() -> Int {\n  let s: String = 1\n  sub(10, 3)\n}\n' > "$rel/broken.vibe"
if invoke check --warn-missing-labels "$rel/broken.vibe" > "$work/broken.out" 2> "$work/broken.err"; then
  fail "a file with an error passed"
fi
if grep -q 'label this argument' "$work/broken.out" "$work/broken.err"; then fail "label rows on a file with errors"; fi
# A leading `require ... = #pkg:..` head is a loader directive the check
# blanks; the warning pass and the codemod must read the file the same way
# (Codex review of #3686). The lanes agree, and the codemod keeps the head.
printf 'require @vibe/core 0.2.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nfn sub(x: Int, y: Int) -> Int {\n  x - y\n}\n\nexport fn main() -> Int {\n  sub(10, 3)\n}\n' > "$rel/pinned.vibe"
invoke check --warn-missing-labels "$rel/pinned.vibe" > "$work/pinned.out" 2> "$work/pinned.err" || fail "a require head turned a clean check into a failure: $(cat "$work/pinned.out")"
[ "$(grep -c 'label this argument' "$work/pinned.err")" = 2 ] || fail "require head rows: $(cat "$work/pinned.err")"
invoke check --warn-missing-labels --json "$rel/pinned.vibe" > "$work/pinned.fs.json" || fail "require head FS JSON exit"
invoke check --single-file --warn-missing-labels --json "$rel/pinned.vibe" > "$work/pinned.sf.json" || fail "require head single-file JSON exit"
cmp "$work/pinned.fs.json" "$work/pinned.sf.json" || fail "require head: the lanes disagree: $(cat "$work/pinned.fs.json") vs $(cat "$work/pinned.sf.json")"
invoke refactor add-labels --write "$rel/pinned.vibe" > "$work/pinned.write" || fail "the codemod refused a require head: $(cat "$work/pinned.write")"
grep -Fq 'sub(x = 10, y = 3)' "$rel/pinned.vibe" || fail "the codemod did not edit the require-headed file"
head -1 "$rel/pinned.vibe" | grep -q '^require @vibe/core 0.2.0 = #pkg:sha1:' || fail "the codemod lost the require head"
invoke check "$rel/pinned.vibe" > "$work/pinned.after" || fail "the edited require-headed file does not check: $(cat "$work/pinned.after")"

# An error from a pass after typing (an inline-wasm lane index) still means
# errors only, on both lanes (Codex review of #3686).
printf 'fn bad_lane(a: Int) -> Int = wasm "(i8x16.extract_lane_s 16 (local.get $a))"\n\nfn sub(x: Int, y: Int) -> Int {\n  x - y\n}\n\nexport fn main() -> Int {\n  bad_lane(1) + sub(10, 3)\n}\n' > "$rel/lane.vibe"
for lane in "" "--single-file"; do
  if invoke check $lane --warn-missing-labels --json "$rel/lane.vibe" > "$work/lane.json"; then
    fail "the lane-index error passed (${lane:-FS lane})"
  fi
  if grep -q 'label this argument' "$work/lane.json"; then fail "label rows beside an error (${lane:-FS lane}): $(cat "$work/lane.json")"; fi
  grep -q 'lane index' "$work/lane.json" || fail "the lane-index error is missing (${lane:-FS lane}): $(cat "$work/lane.json")"
done
echo 'warn-missing-labels: lanes, exit status, JSON parity, codemod agreement, require heads and error files checked'
