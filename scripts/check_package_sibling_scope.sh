#!/usr/bin/env bash
# docs/adding-modules.md, enforced: how one file in a package reaches a function
# defined in a SIBLING file of the same package.
#
# The rule is easy to get wrong in the permissive direction, because "a
# directory-shared package" sounds like the files share a scope. They do not.
# All three of export, contract entry, and an explicit relative import are
# required, and omitting any one of them fails with a DIFFERENT message -- so a
# reader who tries two of the three gets an error that does not name the third.
#
# This is checked rather than only written down because the failure it prevents
# is a design one: someone extracting a helper into a sibling file discovers
# only at the end that every shared helper has to become a declared contract
# entry, which turns private implementation detail into public surface. That
# cost belongs in the plan, not in the last commit (#1849, #2001).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STAGE2="${SIBLING_SCOPE_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  [ -f "$STAGE2" ] || { echo "package-sibling-scope: SIBLING_SCOPE_STAGE2=$STAGE2 does not exist" >&2; exit 1; }
else
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] && { STAGE2="${gen}stage2.wasm"; break; }
  done
  [ -n "${STAGE2:-}" ] || STAGE2="bootstrap/seed/compiler.wasm"
  [ -s "$STAGE2" ] || { echo "package-sibling-scope: no compiler available" >&2; exit 1; }
fi

# Under the preopen dir: the loader resolves these paths from inside wasm.
WORK="$ROOT_DIR/_build/_sibling_scope"
rm -rf "$WORK"; mkdir -p "$WORK/pkg"
trap 'rm -rf "$WORK"' EXIT
fails=0
note() { printf 'package-sibling-scope: ok: %s\n' "$1"; }
bad() { printf 'package-sibling-scope: FAIL: %s\n' "$1" >&2; fails=1; }

cat > "$WORK/use.vibe" <<'VIBE'
import ./pkg { public_entry }

fn main() -> Unit { let _ = public_entry(3) }
VIBE

write_pkg() { # write_pkg <exported?> <declared?> <imported?>
  local exported="$1" declared="$2" imported="$3"
  local kw=""; [ "$exported" = yes ] && kw="export "
  printf '%sfn sib_helper(n: Int) -> Int {\n  n * 2\n}\n' "$kw" > "$WORK/pkg/helper.vibe"
  {
    printf 'name = @scratch/sibscope\nversion = 0.0.1\ndescription =\n  #|sibling scope probe\ndeps = {\n  @vibe/core : 0.2.0\n}\n\ngenerated_hash =\n\n'
    [ "$declared" = yes ] && printf 'fn sib_helper(n: Int) -> Int\n'
    printf 'fn public_entry(n: Int) -> Int\n'
  } > "$WORK/pkg/index.vpkg"
  {
    [ "$imported" = yes ] && printf 'import ./helper.vibe { sib_helper }\n\n'
    printf 'export fn public_entry(n: Int) -> Int {\n  sib_helper(n) + 1\n}\n'
  } > "$WORK/pkg/main_impl.vibe"
}

verdict() {
  rm -f "$WORK/o.wasm" "$WORK/o.wasm.diag"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$WORK/use.vibe" "$WORK/o.wasm" __no_entry__ >/dev/null 2>&1 || true
  if [ -s "$WORK/o.wasm" ]; then echo "COMPILES"; else head -c 400 "$WORK/o.wasm.diag" 2>/dev/null | tr -d '\n'; fi
}

expect() { # expect <label> <export> <declare> <import> <COMPILES|needle>
  local label="$1"; write_pkg "$2" "$3" "$4"; local want="$5"
  local got; got="$(verdict)"
  if [ "$want" = "COMPILES" ]; then
    [ "$got" = "COMPILES" ] && note "$label -> compiles" || bad "$label should compile, got: $got"
  else
    case "$got" in
      COMPILES) bad "$label should be REJECTED but compiled -- the sibling rule got more permissive; update docs/adding-modules.md" ;;
      *"$want"*) note "$label -> rejected: $want" ;;
      *) bad "$label rejected for the wrong reason; want substring [$want], got: $got" ;;
    esac
  fi
}

# The near-complete case: everything present EXCEPT `export`. Without it none
# of the four below isolates the export requirement -- the private case is also
# missing the import, the two middle cases fail for their own omissions, and
# the complete case proves nothing about export on its own. If same-owner
# imports ever started accepting a private function that appears in the
# contract, all four would still pass (#2138 review). Measured: the compiler
# names the omission exactly -- "contract declaration 'sib_helper' is
# implemented but not exported by its implementation file".
expect "declared + imported, but NOT exported"       no  yes yes "is implemented but not exported by its implementation file"
expect "private sibling, no import"                  no  no  no  "unknown name: sib_helper"
expect "exported but not declared in the contract"   yes no  no  "is not declared in the contract"
expect "exported + declared, but not imported"       yes yes no  "unknown name: sib_helper"
expect "exported + declared + explicit ./import"     yes yes yes COMPILES

[ "$fails" -eq 0 ] || exit 1
echo "package-sibling-scope: ok (5 cases; export, contract entry and explicit import are each independently required)"
