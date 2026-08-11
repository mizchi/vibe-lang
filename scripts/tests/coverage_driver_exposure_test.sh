#!/usr/bin/env bash
# #1633: compiler-owned exact-path coverage-driver exposure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
SEED="${VIBE_COV_SEED:-bootstrap/seed/compiler.wasm}"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
FLAT="lib/@vibe/compiler/_cli_adapter_module_source.vibe"
TMP="_build/coverage-driver-exposure-test"
TOOL="$TMP/compiler_cov.wasm"
export VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --experimental-wasm-inlining --stack-size=131072}"

rm -rf "$TMP"
mkdir -p "$TMP"
bash scripts/ensure_generated.sh >/dev/null

# Build the CURRENT compiler under instrumentation. The pinned seed only
# compiles this emitted ordinary source; it does not need to know the new mode.
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$SEED" "$FLAT" "$TOOL" cli_main >/dev/null
[ -s "$TOOL" ] || { echo "coverage-driver-exposure: current compiler_cov.wasm was not produced" >&2; exit 1; }

cat > "$TMP/dep.vibe" <<'VEOF'
fn hidden(x: Int) -> Int { x + 1 }
export fn public_value() -> Int { 40 }
enum Secret { HiddenCtor }
let mut mutable_state = 1
extern let %host_value: (Int) -> Int
VEOF
cat > "$TMP/dup.vibe" <<'VEOF'
fn repeated() -> Int { 1 }
fn repeated() -> Int { 2 }
export fn keep() -> Int { 2 }
VEOF
cat > "$TMP/outside.vibe" <<'VEOF'
fn outside_value() -> Int { 9 }
VEOF
cat > "$TMP/root.vibe" <<'VEOF'
import ./dep.vibe { public_value }
import ./dup.vibe { keep }
export fn root_main() -> Int { public_value() + keep() }
VEOF
cat > "$TMP/positive.vibe" <<'VEOF'
import ./dep.vibe { hidden as selected_hidden }
export fn driver_main() -> Int { selected_hidden(41) }
VEOF

emit_driver() { # driver output entry
  local driver="$1" output="$2" entry="$3"
  rm -f "$output" "$output.diag"
  VIBE_EMIT_COVERAGE_DRIVER_SOURCE=1 \
    VIBE_COVERAGE_DRIVER_PATH="$driver" \
    VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$TOOL" \
    "$TMP/root.vibe" "$output" "$entry" >/dev/null 2>&1 || true
}

# Positive: a private exact-file value imported under an alias is rewritten by
# the shadow-aware production rewriter, retained by DCE, compiled, and run.
emit_driver "$TMP/positive.vibe" "$TMP/positive.out.vibe" driver_main
[ -s "$TMP/positive.out.vibe" ] || { cat "$TMP/positive.out.vibe.diag" >&2; exit 1; }
if grep -q 'selected_hidden' "$TMP/positive.out.vibe"; then
  echo "coverage-driver-exposure: import alias survived instead of being rewritten" >&2
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$SEED" \
  "$TMP/positive.out.vibe" "$TMP/positive.wasm" driver_main >/dev/null
positive_out="$(VIBE_PREOPEN_DIR="$ROOT" bash "$RUNNER" --invoke driver_main "$TMP/positive.wasm" 2>&1 | tail -1)"
[ "$positive_out" = "42" ] || { echo "coverage-driver-exposure: positive run got '$positive_out', want 42" >&2; exit 1; }

# Ordinary merged-source mode remains separate and never appends the driver.
rm -f "$TMP/ordinary.vibe" "$TMP/ordinary.vibe.diag"
VIBE_EMIT_MERGED_SOURCE=1 VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$TOOL" \
  "$TMP/root.vibe" "$TMP/ordinary.vibe" root_main >/dev/null 2>&1 || true
[ -s "$TMP/ordinary.vibe" ] || { cat "$TMP/ordinary.vibe.diag" >&2; exit 1; }
if grep -q 'driver_main' "$TMP/ordinary.vibe"; then
  echo "coverage-driver-exposure: ordinary merged output contains coverage driver" >&2
  exit 1
fi

expect_rejected() { # label driver source diagnostic-fragment
  local label="$1" source="$2" expected="$3"
  local driver="$TMP/$label.vibe" output="$TMP/$label.out.vibe"
  printf '%s\n' "$source" > "$driver"
  emit_driver "$driver" "$output" driver_main
  if [ -s "$output" ]; then
    echo "coverage-driver-exposure: $label unexpectedly emitted source" >&2
    exit 1
  fi
  if [ ! -s "$output.diag" ] || ! grep -Fq "$expected" "$output.diag"; then
    echo "coverage-driver-exposure: $label missing diagnostic '$expected'" >&2
    cat "$output.diag" 2>/dev/null >&2 || true
    exit 1
  fi
}

expect_rejected missing \
  'import ./does-not-exist.vibe { nope }
export fn driver_main() -> Int { 0 }' \
  'target file is missing from the collected compiler closure'
expect_rejected outside \
  'import ./outside.vibe { outside_value }
export fn driver_main() -> Int { outside_value() }' \
  'target exists but is outside the collected compiler closure'
expect_rejected type \
  'import ./dep.vibe { Secret }
export fn driver_main() -> Int { 0 }' \
  'unsupported type'
expect_rejected ctor \
  'import ./dep.vibe { HiddenCtor }
export fn driver_main() -> Int { 0 }' \
  'unsupported constructor'
expect_rejected mutable \
  'import ./dep.vibe { mutable_state }
export fn driver_main() -> Int { 0 }' \
  'unsupported mutable global'
# Extern names require the `%` spelling, which import-item syntax rejects
# before exposure resolution. This is still fail-closed at the parser boundary.
expect_rejected extern \
  'import ./dep.vibe { %host_value }
export fn driver_main() -> Int { 0 }' \
  'expected import item name'
expect_rejected duplicate \
  'import ./dup.vibe { repeated }
export fn driver_main() -> Int { repeated() }' \
  'duplicate top-level value declarations'
expect_rejected local_collision \
  'import ./dep.vibe { hidden as same }
import ./dup.vibe { keep as same }
export fn driver_main() -> Int { same() }' \
  'local import name collides with another request'
expect_rejected driver_collision \
  'import ./dep.vibe { hidden as driver_main }
export fn driver_main() -> Int { 0 }' \
  'driver top-level value collides with an imported local name'
expect_rejected method \
  'import ./dep.vibe { String::hidden_method }
export fn driver_main() -> Int { 0 }' \
  'method and qualified targets are unsupported'

printf 'coverage_driver_exposure_test: ok\n'
