#!/usr/bin/env bash
# Selfhost `vibe test` (#594): compile a .vibe test file (resolving imports from
# the filesystem) with the committed seed compiler, then execute it via the Rust
# runner — no MoonBit host.
#
#   bash scripts/vibe_test.sh [--coverage] <path.vibe | dir> [more paths...]
#
# A test file declares `test "name" { ... }` blocks and (typically) no entry
# function. The selfhost compiler lowers each block into a `__test_<name>`
# function and, when the file has no entry, emits a `_start` that runs every
# test in sequence. `assert` / `assert_eq` trap (wasm `unreachable`) on failure,
# so a clean `_start` run means all of the file's tests passed; a trap means at
# least one failed. Reporting is per file (all-or-nothing); per-test reporting
# is a follow-up. Paths must live under the repo root (the wasm preopen dir).
#
# --coverage (#cov): compile each test file with function/branch hit
# instrumentation, then read the bitmap after a passing run to report which of
# the file's (and its imports') functions and if/match branches the tests
# exercised. Per-file lines + an aggregate are printed; per-file JSON reports
# land in _build/vibe_test/coverage/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Parse flags (only --coverage today); leave the rest as positional paths.
coverage=0
_args=()
for _a in "$@"; do
  if [ "$_a" = "--coverage" ]; then
    coverage=1
  else
    _args+=("$_a")
  fi
done
set -- ${_args[@]+"${_args[@]}"}

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_test.sh [--coverage] <path.vibe | dir> [more paths...]" >&2
  exit 2
fi

seed="$ROOT_DIR/bootstrap/selfhost/seed/selfhost_compiler.wasm"
outdir="$ROOT_DIR/_build/vibe_test"
mkdir -p "$outdir"
covdir="$outdir/coverage"
if [ "$coverage" = "1" ]; then
  mkdir -p "$covdir"
fi

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
cov_fn_total=0
cov_fn_hit=0
cov_br_total=0
cov_br_hit=0
cov_files=0
for src in "${files[@]}"; do
  case "$src" in
    "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
    /*) echo "vibe_test.sh: path must be under the repo root: $src" >&2; exit 2 ;;
    *) src_rel="$src" ;;
  esac
  flat="$(echo "$src_rel" | tr '/' '_' | sed 's/\.vibe$//')"
  out_rel="_build/vibe_test/$flat.wasm"

  # Compile with a sentinel entry name that does not exist in the file, so the
  # compiler takes the no-entry path and emits a test-running `_start`.
  # VIBE_COVERAGE=$coverage selects the instrumented codegen when --coverage.
  if ! VIBE_COVERAGE="$coverage" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke cli_main "$seed" "$src_rel" "$out_rel" "__vibe_test_no_entry__" \
      >/dev/null 2>&1 || [ ! -s "$ROOT_DIR/$out_rel" ]; then
    echo "FAIL (compile) $src_rel"
    fail=$((fail + 1))
    continue
  fi

  cov_out=""
  if [ "$coverage" = "1" ]; then
    cov_out="$covdir/$flat.json"
  fi
  if VIBE_COV_OUT="$cov_out" VIBE_PREOPEN_DIR="$ROOT_DIR" \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
      --invoke _start "$out_rel" >/dev/null 2>&1; then
    if [ "$coverage" = "1" ] && [ -s "$cov_out" ]; then
      # Accumulate + print this file's function/branch coverage.
      read -r f_hit f_total b_hit b_total < <(python3 - "$cov_out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
b = r.get("branch") or {}
print(r.get("hit", 0), r.get("total", 0), b.get("hit", 0), b.get("total", 0))
PY
)
      cov_fn_hit=$((cov_fn_hit + f_hit)); cov_fn_total=$((cov_fn_total + f_total))
      cov_br_hit=$((cov_br_hit + b_hit)); cov_br_total=$((cov_br_total + b_total))
      cov_files=$((cov_files + 1))
      printf 'ok   %s  [cov fn %d/%d, branch %d/%d]\n' "$src_rel" "$f_hit" "$f_total" "$b_hit" "$b_total"
    else
      echo "ok   $src_rel"
    fi
    pass=$((pass + 1))
  else
    echo "FAIL $src_rel"
    fail=$((fail + 1))
  fi
done

echo "[vibe-test] $pass passed, $fail failed (${#files[@]} files)"
if [ "$coverage" = "1" ] && [ "$cov_files" -gt 0 ]; then
  fn_pct=$(python3 -c "print(f'{($cov_fn_hit/$cov_fn_total*100) if $cov_fn_total else 0:.2f}')")
  br_pct=$(python3 -c "print(f'{($cov_br_hit/$cov_br_total*100) if $cov_br_total else 0:.2f}')")
  echo "[vibe-test] coverage: functions $cov_fn_hit/$cov_fn_total (${fn_pct}%), branches $cov_br_hit/$cov_br_total (${br_pct}%) over $cov_files file(s)"
  echo "[vibe-test] per-file coverage JSON: $covdir/"
fi
[ "$fail" -eq 0 ]
