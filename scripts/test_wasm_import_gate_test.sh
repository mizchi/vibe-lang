#!/usr/bin/env bash
# Self-test for scripts/test_wasm_import_gate.sh (#2248): the gate must FAIL
# when a real input is mutated, and pass on an unmutated copy.
#
#   VIBE_STAGE2_WASM=<stage2.wasm> bash scripts/test_wasm_import_gate_test.sh
#
# Each case copies fixtures/wasm_import into a scratch directory inside the
# tree (the imports record tree-relative paths), applies one mutation,
# checks the mutation actually landed, and runs the gate on the copy.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${VIBE_STAGE2_WASM:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "test_wasm_import_gate_test.sh: set VIBE_STAGE2_WASM to a stage2 compiler" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
unset WASM_IMPORT_GATE_FIXTURES VIBE_WASM_LINK_DIR

REL="_build/test_wasm_import_gate_test"
SCRATCH="$ROOT_DIR/$REL"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "[wasm-import-gate-test] FAIL $*" >&2; exit 1; }

fresh() {
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  cp -R fixtures/wasm_import "$SCRATCH/fx"
  ln -s "$CLI" "$SCRATCH/compiler.wasm"
  [ "$CLI" -ef "$SCRATCH/compiler.wasm" ] || fail "the selected compiler link does not match"
}
# mutate <file> <from> <to>: replace, and prove the edit landed.
mutate() {
  local f="$SCRATCH/fx/$1"
  grep -qF -- "$2" "$f" || fail "mutation target '$2' not in $1"
  FROM="$2" TO="$3" python3 -c 'import os,sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace(os.environ["FROM"], os.environ["TO"], 1))' "$f"
  grep -qF -- "$3" "$f" || fail "mutation of $1 did not land"
}
# A relative compiler path must still name this exact artifact after the
# gate changes into a package subdirectory. Every control uses that path.
run_gate() { WASM_IMPORT_GATE_FIXTURES="$REL/fx" bash "$ROOT_DIR/scripts/test_wasm_import_gate.sh" "$REL/compiler.wasm" >"$SCRATCH.out" 2>&1; }
expect_fail() { # <label> <message substring>
  if run_gate; then cat "$SCRATCH.out" >&2; fail "$1: the gate passed"; fi
  grep -qF -- "$2" "$SCRATCH.out" || { cat "$SCRATCH.out" >&2; fail "$1: the gate failed for another reason"; }
  echo "ok: $1"
}

# 0. An unmutated copy passes, so a failure below is the mutation's.
fresh
run_gate || { cat "$SCRATCH.out" >&2; fail "the gate fails on an unmutated copy"; }
echo "ok: unmutated copy passes"

# 1. A wrong answer is caught.
fresh; mutate counter_main.vibex "bump(40)" "bump(41)"
expect_fail "a different count" "printed count=43, want count=42"

# 2. An extra foreign call shows in the import set (the tree-shake check).
fresh; mutate counter_main.vibex "  bump(40)" "  let _ = is_all_ones(0)
  bump(40)"
mutate counter_main.vibex "add_i32, bump, count" "add_i32, bump, count, is_all_ones"
expect_fail "an extra import" "want 'Add_I32 bump count'"

# 3. An in-range argument is accepted, so the refusal row must notice.
fresh; mutate err_core_i32_range.vibe "add_i32(4294967296, 1)" "add_i32(4294967295, 1)"
expect_fail "an i32 refusal that does not fire" "an i32 argument outside UInt32 was accepted"

# 4. A component answer that differs is caught.
fresh; mutate greeter_main.vibex 'greet("vibe")' 'greet("vibes")'
expect_fail "a different component answer" "greeter_main printed"

# 5. The shared-memory accessors are checked by value, not by exit status.
fresh; mutate shared_memory_main.vibex "wasm_memory_store_u8(5, 7)" "wasm_memory_store_u8(5, 8)"
expect_fail "a different shared-memory answer" "peek=8\\ size=65536, want load=42 peek=7"

# 6. An initializer whose effect differs is caught.
# The gate links the committed binary, so patch it (`i64.const 7` is the
# byte pair 42 07, once in the file) rather than needing wat2wasm here.
fresh
python3 -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); assert b.count(b"\x42\x07")==1, "patch target not unique"; open(p,"wb").write(b.replace(b"\x42\x07", b"\x42\x08"))' "$SCRATCH/fx/reactor.wasm" || fail "could not patch reactor.wasm"
expect_fail "a different initializer effect" "init_main printed value=8\\ foo=42"

echo "[wasm-import-gate-test] ok (7 cases)"
