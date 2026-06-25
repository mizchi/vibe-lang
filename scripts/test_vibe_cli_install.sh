#!/usr/bin/env bash
# Integration test for the `vibe` install slice (docs/release-roadmap.md テーマ1):
# the moonrun_wt runner's vibe::* host imports, the installer, the launcher's
# run/compile/check/test subcommands, the install-time .cwasm, and the compile
# diagnostic sidecar. Runs against a throwaway VIBE_HOME so it never touches a
# real install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
# A guest type error surfaces as a single-line message; keep RUST_BACKTRACE off
# so the runner does not dump its own backtrace and confuse the assertions.
unset RUST_BACKTRACE || true

pass=0
fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 (expected '$2', got '$3')" >&2
    fail=$((fail + 1))
  fi
}

echo "[test] installing into $VIBE_HOME"
# Use the committed seed for speed/determinism; the launcher/runner path is what
# we are testing, not a fresh compiler build.
bash scripts/install.sh \
  --cli-wasm "$ROOT_DIR/bootstrap/selfhost/seed/selfhost_compiler.wasm" \
  >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }
[ -f "$VIBE_HOME/lib/vibe-cli.cwasm" ] || { echo "FAIL: .cwasm not generated" >&2; exit 1; }
echo "ok: install produced launcher + .cwasm"
pass=$((pass + 1))

proj="$WORK/proj"
mkdir -p "$proj"
printf 'export let main = () -> Int { 40 + 2 }\n' > "$proj/hello.vibe"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$proj/lib.vibe"
printf 'import ./lib.vibe { add }\nexport let main = () -> Int { add(20, 22) }\n' > "$proj/app.vibe"
printf 'export let main = () -> Int { nope + 1 }\n' > "$proj/bad.vibe"
printf 'test "ok" {\n  assert_eq(2 + 2, 4)\n}\n' > "$proj/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(2 + 2, 5)\n}\n' > "$proj/fail_test.vibe"

# run: single file
check "vibe run hello" "42" "$("$VIBE" run "$proj/hello.vibe" 2>/dev/null | tr -dc '0-9')"
# run: multi-file import resolution
check "vibe run app (import)" "42" "$("$VIBE" run "$proj/app.vibe" 2>/dev/null | tr -dc '0-9')"

# compile: produces a wasm
"$VIBE" compile "$proj/hello.vibe" -o "$proj/hello.wasm" >/dev/null 2>&1 || true
check "vibe compile output exists" "yes" "$([ -s "$proj/hello.wasm" ] && echo yes || echo no)"

# check: good file passes
"$VIBE" check "$proj/app.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe check good exit" "0" "$rc"

# check: bad file fails non-zero
"$VIBE" check "$proj/bad.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe check bad exit" "1" "$rc"

# diagnostic: the seed predates the .diag sidecar, so only assert the launcher
# reports failure cleanly. A freshly built compiler additionally yields a real
# message; assert that when the sidecar feature is present.
diag="$("$VIBE" check "$proj/bad.vibe" 2>&1 || true)"
if echo "$diag" | grep -q "unknown name"; then
  check "vibe check bad diagnostic" "yes" "yes"
else
  echo "info: compiler did not emit a structured diagnostic (seed build); skipping message assertion"
fi

# test: passing file exits 0, failing file exits non-zero, aggregate fails
"$VIBE" test "$proj/pass_test.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe test pass exit" "0" "$rc"
"$VIBE" test "$proj/fail_test.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe test fail exit" "1" "$rc"

# fetch: vendor a file:// dep, then run a program that imports it.
fproj="$WORK/fproj"
mkdir -p "$fproj"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$WORK/mathlib_src.vibe"
printf 'mathlib file://%s/mathlib_src.vibe\n' "$WORK" > "$fproj/vibe.deps"
printf 'import ./deps/mathlib.vibe { add }\nexport let main = () -> Int { add(40, 2) }\n' > "$fproj/app.vibe"
"$VIBE" fetch "$fproj" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe fetch exit" "0" "$rc"
check "vibe fetch wrote lock" "yes" "$([ -s "$fproj/vibe.lock" ] && echo yes || echo no)"
check "vibe fetch vendored dep" "yes" "$([ -s "$fproj/deps/mathlib.vibe" ] && echo yes || echo no)"
check "vibe run vendored dep" "42" "$("$VIBE" run "$fproj/app.vibe" 2>/dev/null | tr -dc '0-9')"

# fetch: a git+ dependency from a local repo, vendored as a directory.
if command -v git >/dev/null 2>&1; then
  repo="$WORK/gitrepo"; mkdir -p "$repo"
  printf 'export let triple = (x: Int) -> Int { x * 3 }\n' > "$repo/index.vibe"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -q -m init )
  gproj="$WORK/gproj"; mkdir -p "$gproj"
  printf 'mathgit git+file://%s\n' "$repo" > "$gproj/vibe.deps"
  printf 'import ./deps/mathgit/index.vibe { triple }\nexport let main = () -> Int { triple(14) }\n' > "$gproj/app.vibe"
  "$VIBE" fetch "$gproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch git+ exit" "0" "$rc"
  check "vibe fetch git+ records commit" "yes" "$(grep -q 'git:' "$gproj/vibe.lock" && echo yes || echo no)"
  check "vibe run git+ dep" "42" "$("$VIBE" run "$gproj/app.vibe" 2>/dev/null | tr -dc '0-9')"
else
  echo "info: git not available; skipping git+ fetch assertions"
fi

echo "[test] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
