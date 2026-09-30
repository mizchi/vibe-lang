#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
compiler="${VIBE_TEST_CLI_WASM:?set VIBE_TEST_CLI_WASM to the current checkout stage2}"
work="$(mktemp -d "$ROOT_DIR/_build/extract-function.XXXXXX")"
trap 'rm -rf "$work"' EXIT
rel="${work#"$ROOT_DIR/"}"
source_path="$rel/input.vibe"
cat > "$source_path" <<'VIBE'
export fn main() -> Int {
  let x = 4
  x * 2 + 3
}
VIBE
cp "$source_path" "$work/original.vibe"
read -r start end < <(python3 - "$source_path" <<'PY'
import sys
source = open(sys.argv[1], 'rb').read()
selection = b'x * 2 + 3'
start = source.index(selection)
print(start, start + len(selection))
PY
)

invoke() {
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$compiler" "$@"
}

VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$compiler" \
  runtime/vibe refactor extract-function "$source_path" "$start" "$end" calculate > "$work/preview.vibe"
VIBE_RUNNER=/nonexistent runtime/vibe refactor --help > "$work/help.out"
grep -q '^usage: vibe refactor extract-function' "$work/help.out"
cmp "$source_path" "$work/original.vibe"
grep -Fq 'calculate(x)' "$work/preview.vibe"
grep -Fq 'let calculate = (x: Int)' "$work/preview.vibe"
invoke refactor extract-function "$source_path" "$start" "$end" calculate --write > "$work/write.out"
cmp "$source_path" "$work/preview.vibe"
test ! -s "$work/write.out"
invoke compile "$source_path" -o "$rel/result.wasm" --entry main > "$work/compile.out"
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$rel/result.wasm" > "$work/value.out"
grep -qx '11' "$work/value.out"

for args in 'bad 999999 calculate' '0 999999 calculate' '0 1 if'; do
  cp "$source_path" "$work/before.vibe"
  read -r a b name <<< "$args"
  if invoke refactor extract-function "$source_path" "$a" "$b" "$name" --write > "$work/error.out" 2>&1; then
    echo 'extract-function: an invalid request succeeded' >&2
    exit 1
  fi
  cmp "$source_path" "$work/before.vibe"
done
echo 'extract-function: preview, write, execution, and refusal checks passed'
