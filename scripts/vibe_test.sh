#!/usr/bin/env bash
# Selfhost `vibe test` (#594): compile a .vibe test file (resolving imports from
# the filesystem) with the committed seed compiler, then execute it via the Rust
# runner — no MoonBit host.
#
#   bash scripts/vibe_test.sh <path.vibe | dir> [more paths...]
#
# A test file declares `test "name" { ... }` blocks and (typically) no entry
# function. The selfhost compiler lowers each block into a `__test_<name>`
# function and, when the file has no entry, emits a `_start` that runs every
# test in sequence. `assert` / `assert_eq` trap (wasm `unreachable`) on failure,
# so a clean `_start` run means all of the file's tests passed; a trap means at
# least one failed. Reporting is per file (all-or-nothing); per-test reporting
# is a follow-up. Paths must live under the repo root (the wasm preopen dir).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_test.sh <path.vibe | dir> [more paths...]" >&2
  exit 2
fi

seed="$ROOT_DIR/bootstrap/selfhost/seed/selfhost_compiler.wasm"
outdir="$ROOT_DIR/_build/vibe_test"
mkdir -p "$outdir"

# Collect the test files: explicit .vibe files, or every *_test.vibe under a dir.
files=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find "$arg" -type f -name '*_test.vibe' | sort)
  elif [ -f "$arg" ]; then
    files+=("$arg")
  else
    echo "vibe_test.sh: not found: $arg" >&2
    exit 2
  fi
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "vibe_test.sh: no test files found" >&2
  exit 2
fi

pass=0
fail=0
for src in "${files[@]}"; do
  case "$src" in
    "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
    /*) echo "vibe_test.sh: path must be under the repo root: $src" >&2; exit 2 ;;
    *) src_rel="$src" ;;
  esac
  out_rel="_build/vibe_test/$(echo "$src_rel" | tr '/' '_' | sed 's/\.vibe$//').wasm"

  # Compile with a sentinel entry name that does not exist in the file, so the
  # compiler takes the no-entry path and emits a test-running `_start`.
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main "$seed" "$src_rel" "$out_rel" "__vibe_test_no_entry__" \
      >/dev/null 2>&1 || [ ! -s "$ROOT_DIR/$out_rel" ]; then
    echo "FAIL (compile) $src_rel"
    fail=$((fail + 1))
    continue
  fi

  if VIBE_PREOPEN_DIR="$ROOT_DIR" \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke _start "$out_rel" >/dev/null 2>&1; then
    echo "ok   $src_rel"
    pass=$((pass + 1))
  else
    echo "FAIL $src_rel"
    fail=$((fail + 1))
  fi
done

echo "[vibe-test] $pass passed, $fail failed (${#files[@]} files)"
[ "$fail" -eq 0 ]
