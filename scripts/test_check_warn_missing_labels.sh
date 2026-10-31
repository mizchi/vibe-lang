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
echo 'warn-missing-labels: lanes, exit status, JSON parity, codemod agreement and error files checked'
