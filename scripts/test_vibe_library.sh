#!/usr/bin/env bash
# Smoke-test a curated allow-list of library `*_test.vibe` files through the
# installed selfhost `vibe test`. This is the regression net for vibe/wasm,
# vibe/x and vibe/prelude library modules, which the selfhost-only gate does NOT
# cover (it only validates the compiler self-compile). The MoonBit host that used
# to run the full suite via flaker was retired in #594.
#
# WHY AN ALLOW-LIST, not "run everything": only a subset of library tests
# currently COMPILES under the selfhost CLI — many use builtins it doesn't yet
# support (Double::parse, FixedArray::make, `s[i]` string indexing, char_at,
# int_to_string resolution, …) and fail to compile, independent of any change
# here. Gating on "all tests" would be permanently red. This list is the
# known-green subset (verified stable across repeated runs); it catches a
# regression that turns a passing module red. When a new builtin lands and more
# tests go green, add them here.
#
# Fresh throwaway install into VIBE_HOME/VIBE_BIN_DIR (mirrors test_vibe_bench.sh)
# so it never touches a real install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The known-green library tests (selfhost-CLI-compilable subset). Covers the
# wasm parsers touched by the O(N²) StringBuilder work (#660/#662) plus prelude
# and a few vibe/x modules with real logic.
ALLOW=(
  vibe/prelude/func_test.vibe
  vibe/prelude/lazy_iter_test.vibe
  vibe/wasm/component_parser/component_parser_test.vibe
  vibe/wasm/wasm_parser/wasm_parser_test.vibe
  vibe/wasm/wat_parser/wat_parser_test.vibe
  vibe/x/args/parser_import_test.vibe
  vibe/x/collect/collect_effect_test.vibe
  vibe/x/collect/collect_test.vibe
  vibe/x/jsonschema/validate_test.vibe
  vibe/x/math/math_test.vibe
  vibe/x/scan/index_import_test.vibe
)

RT="$ROOT_DIR/tools/moonrun_wasmtime/target/release/moonrun_wt"
if [ ! -x "$RT" ] || [ -n "$(find tools/moonrun_wasmtime/src -name "*.rs" -newer "$RT" 2>/dev/null | head -1)" ]; then
  cargo build --release --manifest-path tools/moonrun_wasmtime/Cargo.toml >/dev/null
fi

cli="$(bash scripts/build_cli_wasm.sh)"
[ -s "$cli" ] || { echo "FAIL: no CLI wasm built" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
unset RUST_BACKTRACE || true

echo "[test] installing fresh CLI into $VIBE_HOME"
bash scripts/install.sh --cli-wasm "$cli" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }

# Per-test wall-clock guard. macOS has no GNU `timeout` (and ships bash 3.2,
# where an empty-array expansion under `set -u` is itself an error), so dispatch
# through a function: use `timeout`/`gtimeout` when present, else run directly
# (the job-level timeout still bounds a true hang).
run_guarded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 150 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 150 "$@"
  else
    "$@"
  fi
}

pass=0; fail=0
for t in "${ALLOW[@]}"; do
  if [ ! -f "$t" ]; then
    echo "FAIL: allow-listed test no longer exists: $t" >&2
    fail=$((fail + 1))
    continue
  fi
  # `vibe test` prints `ok:   <file>` on success; a compile/assert failure prints
  # `FAIL …`. Capture the last line and require an `ok:`.
  last="$(run_guarded "$VIBE" test "$t" 2>&1 | tail -1 || true)"
  if printf '%s' "$last" | grep -q "^ok:"; then
    echo "ok: $t"
    pass=$((pass + 1))
  else
    echo "FAIL: $t — $last" >&2
    fail=$((fail + 1))
  fi
done

echo "[test_vibe_library] $pass passed, $fail failed (of ${#ALLOW[@]} allow-listed)"
[ "$fail" -eq 0 ] || exit 1
