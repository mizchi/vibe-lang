#!/usr/bin/env bash
# ADR-0120 Phase 2a (#3679): `vibe refactor add-labels` end to end. The callee
# lives in another module, so the label must come from the checker's
# import-resolved binding. The default only reports; --write rewrites; the
# rewritten program gives the same answer; a second run makes no edits.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
compiler="${VIBE_TEST_CLI_WASM:?set VIBE_TEST_CLI_WASM to the current checkout stage2}"
mkdir -p "$ROOT_DIR/_build"
work="$(mktemp -d "$ROOT_DIR/_build/add-labels.XXXXXX")"
trap 'rm -rf "$work"' EXIT
rel="${work#"$ROOT_DIR/"}"
cat > "$rel/dep.vibe" <<'VIBE'
export fn sub(x: Int, y: Int) -> Int {
  x - y
}
VIBE
cat > "$rel/main.vibe" <<'VIBE'
import ./dep.vibe { sub }

export fn main() -> Int {
  let f = (a: Int, b: Int) -> Int { a - b }
  sub(10, 3) + f(1, 2)
}
VIBE
cp "$rel/main.vibe" "$work/original.vibe"

invoke() {
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$compiler" "$@"
}

invoke refactor add-labels "$rel/main.vibe" > "$work/report.out"
cmp "$rel/main.vibe" "$work/original.vibe"
grep -q ':5:3: sub +2$' "$work/report.out"
grep -q '^add-labels: 2 labels in 1 calls;' "$work/report.out"
grep -q ', 1 through a local lambda,' "$work/report.out"

invoke refactor add-labels --write "$rel/main.vibe" > "$work/write.out"
grep -Fq 'sub(x = 10, y = 3) + f(1, 2)' "$rel/main.vibe"
invoke compile "$rel/main.vibe" -o "$rel/result.wasm" --entry main > "$work/compile.out"
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$rel/result.wasm" > "$work/value.out"
grep -qx '6' "$work/value.out"

cp "$rel/main.vibe" "$work/written.vibe"
invoke refactor add-labels --write "$rel/main.vibe" > "$work/again.out"
cmp "$rel/main.vibe" "$work/written.vibe"
grep -q '^add-labels: 0 labels in 0 calls;' "$work/again.out"

# A file that does not check is named, left alone, and fails the run.
printf 'export fn main() -> Int {\n  let s: String = 1\n  0\n}\n' > "$rel/broken.vibe"
cp "$rel/broken.vibe" "$work/broken.before"
if invoke refactor add-labels --write "$rel/broken.vibe" > "$work/broken.out" 2>&1; then
  echo 'add-labels: a file that does not check was reported as done' >&2
  exit 1
fi
cmp "$rel/broken.vibe" "$work/broken.before"
grep -q 'not checked, left alone' "$work/broken.out"
echo 'add-labels: report, write, execution, idempotence and refusal checks passed'
