#!/usr/bin/env bash
# #1549: cross-module import-boundary fixtures for trait definitions and
# impls. Import assembly used to project only the dependency's flat VALUE
# bindings, so the FS/import path could not see dependency trait defs or
# impls and deliberately skipped user-trait bound enforcement — a bound
# violation against an imported trait checked ok and died (or miscompiled)
# later. These fixtures pin the closed boundary from both sides:
#
#   1. valid cross-module trait/impl use still checks ok (no false positive),
#   2. a bound violation against an imported trait fails with the same
#      `no impl` diagnostic the single-module path produces (parity),
#   3. the trait def flows under an import alias,
#   4. impls flow transitively (dep-of-dep) with the dependency environment.
#
# Struct/enum/alias definitions and effect declarations are still outside the
# transported TypeEnv (#1550); this gate intentionally does not claim them.
#
# Usage: bash scripts/check_import_boundary.sh <stage2.wasm>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
stage2="${1:?usage: check_import_boundary.sh <stage2.wasm>}"
# run_check cds into the throwaway project, so the compiler path must survive.
case "$stage2" in
  /*) ;;
  *) stage2="$(cd "$(dirname "$stage2")" && pwd)/$(basename "$stage2")" ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/vibe-import-boundary-XXXXXX")"
trap 'rm -rf "$work"' EXIT
proj="$work/proj"
mkdir -p "$proj"

run_check() {
  # run_check <entry> <out>: check-only via the node host runner, isolated
  # cache. Entry and output paths are project-relative, so run from $proj.
  (cd "$proj" && VIBE_BUILD_CACHE_DIR="$work/cache" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    VIBE_HOME="$work/home" VIBE_PREOPEN_DIR="$proj" \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$stage2" "$1" "$2" >/dev/null 2>&1) || true
}

expect_ok() {
  local name="$1"
  run_check "$name.vibe" "$name.out"
  if [ "$(cat "$proj/$name.out" 2>/dev/null)" != "ok" ]; then
    echo "[import-boundary] FAIL: $name expected ok, got: $(head -c 200 "$proj/$name.out.diag" 2>/dev/null || echo '<no output>')" >&2
    exit 1
  fi
}

expect_diag() {
  local name="$1" needle="$2"
  run_check "$name.vibe" "$name.out"
  if [ -s "$proj/$name.out" ] && [ "$(cat "$proj/$name.out")" = "ok" ]; then
    echo "[import-boundary] FAIL: $name unexpectedly checked ok" >&2
    exit 1
  fi
  if ! grep -q "$needle" "$proj/$name.out.diag" 2>/dev/null; then
    echo "[import-boundary] FAIL: $name diagnostic missing '$needle': $(head -c 200 "$proj/$name.out.diag" 2>/dev/null)" >&2
    exit 1
  fi
}

cat > "$proj/dep.vibe" <<'EOF'
export trait Greet { greet(Int) -> Int }
export struct Thing { n: Int }
impl Greet for Thing { greet(self, x: Int) -> Int { self.n + x } }
export fn make(n: Int) -> Thing { Thing::{ n: n } }
EOF

# 1. Valid cross-module use: the imported trait def and the dependency's impl
#    satisfy the bound.
cat > "$proj/use_ok.vibe" <<'EOF'
import ./dep.vibe { Greet, make }
fn call_it[T: Greet](t: T, x: Int) -> Int { t.greet(x) }
fn main() -> Int { call_it(make(1), 2) }
EOF
expect_ok use_ok

# 2. Bound violation against the imported trait: same `no impl` shape as the
#    single-module path.
cat > "$proj/use_bad.vibe" <<'EOF'
import ./dep.vibe { Greet, make }
fn call_it[T: Greet](t: T, x: Int) -> Int { t.greet(x) }
fn main() -> Int { call_it(3, 2) }
EOF
expect_diag use_bad "no impl \`Greet\` for \`Int\`"

# 2b. Single-module parity control for the same violation.
cat > "$proj/control_bad.vibe" <<'EOF'
trait GreetL { greetl(Int) -> Int }
struct ThingL { n: Int }
impl GreetL for ThingL { greetl(self, x: Int) -> Int { self.n + x } }
fn call_it[T: GreetL](t: T, x: Int) -> Int { t.greetl(x) }
fn main() -> Int { call_it(3, 2) }
EOF
expect_diag control_bad "no impl \`GreetL\` for \`Int\`"

# 3. The trait def flows under an import alias.
cat > "$proj/use_alias.vibe" <<'EOF'
import ./dep.vibe { Greet as Salute, make }
fn call_it[T: Salute](t: T, x: Int) -> Int { t.greet(x) }
fn main() -> Int { call_it(make(1), 2) }
EOF
expect_ok use_alias

# 4. Impls flow transitively: mid re-exports nothing impl-shaped explicitly,
#    but its checked environment carries dep's impl to the consumer.
cat > "$proj/mid.vibe" <<'EOF'
import ./dep.vibe { Greet, Thing, make }
export fn make_two() -> Thing { make(2) }
EOF
cat > "$proj/use_transitive.vibe" <<'EOF'
import ./dep.vibe { Greet }
import ./mid.vibe { make_two }
fn call_it[T: Greet](t: T, x: Int) -> Int { t.greet(x) }
fn main() -> Int { call_it(make_two(), 2) }
EOF
expect_ok use_transitive

echo "[import-boundary] ok: cross-module trait/impl boundary fixtures pass"
