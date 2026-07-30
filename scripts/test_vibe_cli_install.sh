#!/usr/bin/env bash
# Integration test for the `vibe` install slice (docs/release-roadmap.md テーマ1):
# the viberun runner's vibe::* host imports, the installer, the launcher's
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

run_number() {
  "$VIBE" run "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1
}

echo "[test] installing into $VIBE_HOME"
# Use the committed seed for speed/determinism; the launcher/runner path is what
# we are testing, not a fresh compiler build.
bash scripts/install.sh \
  --cli-wasm "$ROOT_DIR/bootstrap/seed/compiler.wasm" \
  >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }
# Toolchain layout (#755): the AOT artifact lives under toolchains/<name>/lib
# (the flat path is the pre-toolchain layout, kept as a fallback assertion).
[ -f "$VIBE_HOME/toolchains/main/lib/vibe-cli.cwasm" ] || [ -f "$VIBE_HOME/lib/vibe-cli.cwasm" ] \
  || { echo "FAIL: .cwasm not generated" >&2; exit 1; }
[ -f "$VIBE_HOME/toolchain" ] || { echo "FAIL: default toolchain file not written" >&2; exit 1; }
[ -f "$VIBE_HOME/lib/@vibe/core/index.vpkg" ] || [ -f "$VIBE_HOME/lib/@vibe/core/index.vibei" ] || { echo "FAIL: stdlib @vibe/core not materialized" >&2; exit 1; }
echo "ok: install produced launcher + .cwasm + default toolchain + stdlib"
pass=$((pass + 1))

proj="$WORK/proj"
mkdir -p "$proj"
printf 'fn main with { Stdout } { Stdout::write_stream("42\\n") }\n' > "$proj/hello.vibex"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$proj/lib.vibe"
printf 'import ./lib.vibe { add }\nfn main with { Stdout } { Stdout::write_stream("\\{add(20, 22)}\\n") }\n' > "$proj/app.vibex"
printf 'fn main with { } { let _ = nope + 1; () }\n' > "$proj/bad.vibex"
printf 'test "ok" {\n  assert_eq(2 + 2, 4)\n}\n' > "$proj/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(2 + 2, 5)\n}\n' > "$proj/fail_test.vibe"

# run: single file
check "vibe run hello" "42" "$(run_number "$proj/hello.vibex")"
# run: multi-file import resolution
check "vibe run app (import)" "42" "$(run_number "$proj/app.vibex")"

# compile: produces a wasm
"$VIBE" compile "$proj/hello.vibex" -o "$proj/hello.wasm" >/dev/null 2>&1 || true
check "vibe compile output exists" "yes" "$([ -s "$proj/hello.wasm" ] && echo yes || echo no)"

# check: good file passes
"$VIBE" check "$proj/app.vibex" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe check good exit" "0" "$rc"

# check: bad file fails non-zero
"$VIBE" check "$proj/bad.vibex" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe check bad exit" "1" "$rc"

# normalize (#882): --check flags an unnormalized file, in-place write fixes it
printf 'fn nrm_helper(x: Int) -> Int {\n  x + 1\n}\n\nexport fn nrm_entry(n: Int) -> Int {\n  nrm_helper(n)\n}\n' > "$proj/nrm.vibe"
"$VIBE" normalize --check "$proj/nrm.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe normalize --check flags unnormalized" "1" "$rc"
"$VIBE" normalize "$proj/nrm.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe normalize write exit" "0" "$rc"
"$VIBE" normalize --check "$proj/nrm.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe normalize --check clean after write" "0" "$rc"

# diagnostic: the seed predates the .diag sidecar, so only assert the launcher
# reports failure cleanly. A freshly built compiler additionally yields a real
# message; assert that when the sidecar feature is present.
diag="$("$VIBE" check "$proj/bad.vibex" 2>&1 || true)"
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

# shell (#805): compiled REPL, accumulate + recompile. Scripted (non-tty)
# session: declare a fn, evaluate an expression using it, feed a bad line
# (must be rejected with a diagnostic, session must survive), then evaluate
# another expression against the still-intact buffer.
shell_err="$WORK/shell.err"
shell_out="$(printf '%s\n' \
  'fn double(x: Int) -> Int { x * 2 }' \
  'double(21)' \
  'this is not vibe !!!' \
  'double(10) + 1' \
  ':quit' \
  | "$VIBE" shell 2>"$shell_err" || true)"
check "vibe shell declares + evaluates" "42" "$(printf '%s\n' "$shell_out" | sed -n 1p)"
check "vibe shell survives a bad line" "21" "$(printf '%s\n' "$shell_out" | sed -n 2p)"
check "vibe shell reports the bad line" "yes" "$(grep -q 'error' "$shell_err" && echo yes || echo no)"

# fetch: vendor a file:// dep, then run a program that imports it.
fproj="$WORK/fproj"
mkdir -p "$fproj"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$WORK/mathlib_src.vibe"
printf 'mathlib file://%s/mathlib_src.vibe\n' "$WORK" > "$fproj/vibe.deps"
printf 'import ./deps/mathlib.vibe { add }\nfn main with { Stdout } { Stdout::write_stream("\\{add(40, 2)}\\n") }\n' > "$fproj/app.vibex"
"$VIBE" fetch "$fproj" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe fetch exit" "0" "$rc"
check "vibe fetch wrote lock" "yes" "$([ -s "$fproj/vibe.lock" ] && echo yes || echo no)"
check "vibe fetch vendored dep" "yes" "$([ -s "$fproj/deps/mathlib.vibe" ] && echo yes || echo no)"
check "vibe run vendored dep" "42" "$(run_number "$fproj/app.vibex")"

# fetch: a git+ dependency from a local repo, vendored as a directory.
if command -v git >/dev/null 2>&1; then
  repo="$WORK/gitrepo"; mkdir -p "$repo"
  printf 'export let triple = (x: Int) -> Int { x * 3 }\n' > "$repo/index.vibe"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -q -m init )
  gproj="$WORK/gproj"; mkdir -p "$gproj"
  printf 'mathgit git+file://%s\n' "$repo" > "$gproj/vibe.deps"
  printf 'import ./deps/mathgit/index.vibe { triple }\nfn main with { Stdout } { Stdout::write_stream("\\{triple(14)}\\n") }\n' > "$gproj/app.vibex"
  "$VIBE" fetch "$gproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch git+ exit" "0" "$rc"
  check "vibe fetch git+ records commit" "yes" "$(grep -q 'git:' "$gproj/vibe.lock" && echo yes || echo no)"
  check "vibe run git+ dep" "42" "$(run_number "$gproj/app.vibex")"

  # transitive: project -> A (git) -> B (git); A declares B in its own vibe.deps
  rb="$WORK/rb"; mkdir -p "$rb"
  printf 'export let base = (x: Int) -> Int { x * 10 }\n' > "$rb/index.vibe"
  ( cd "$rb" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -q -m b )
  ra="$WORK/ra"; mkdir -p "$ra"
  printf 'base git+file://%s\n' "$rb" > "$ra/vibe.deps"
  printf 'import ./deps/base/index.vibe { base }\nexport let mid = (x: Int) -> Int { base(x) + 2 }\n' > "$ra/index.vibe"
  ( cd "$ra" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -q -m a )
  tproj="$WORK/tproj"; mkdir -p "$tproj"
  printf 'a git+file://%s\n' "$ra" > "$tproj/vibe.deps"
  printf 'import ./deps/a/index.vibe { mid }\nfn main with { Stdout } { Stdout::write_stream("\\{mid(4)}\\n") }\n' > "$tproj/app.vibex"
  "$VIBE" fetch "$tproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch transitive exit" "0" "$rc"
  check "vibe fetch vendored nested dep" "yes" "$([ -s "$tproj/deps/a/deps/base/index.vibe" ] && echo yes || echo no)"
  check "vibe run transitive dep tree" "42" "$(run_number "$tproj/app.vibex")"

  # --frozen: pin to the lock's commit even after upstream moves on.
  fzproj="$WORK/fzproj"; mkdir -p "$fzproj"
  printf 'mathgit git+file://%s\n' "$repo" > "$fzproj/vibe.deps"
  "$VIBE" fetch "$fzproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch (pre-frozen) exit" "0" "$rc"
  pinsha="$(awk '/^mathgit/{print $3}' "$fzproj/vibe.lock" | sed 's/git://')"
  # Move the upstream repo forward so HEAD != the locked commit.
  printf 'export let triple = (x: Int) -> Int { x * 4 }\n' > "$repo/index.vibe"
  ( cd "$repo" && git add -A && git commit -q -m bump )
  # Re-fetch with --frozen: must restore the *old* commit's source (x*3).
  "$VIBE" fetch --frozen "$fzproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch --frozen exit" "0" "$rc"
  printf 'import ./deps/mathgit/index.vibe { triple }\nfn main with { Stdout } { Stdout::write_stream("\\{triple(14)}\\n") }\n' > "$fzproj/app.vibex"
  check "vibe fetch --frozen pins commit" "42" "$(run_number "$fzproj/app.vibex")"
  newsha="$(awk '/^mathgit/{print $3}' "$fzproj/vibe.lock" | sed 's/git://')"
  check "vibe fetch --frozen keeps lock sha" "$pinsha" "$newsha"

  # verify: clean tree passes, tampering a vendored git dep is detected.
  "$VIBE" verify "$gproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe verify clean exit" "0" "$rc"
  printf 'export let triple = (x: Int) -> Int { x * 999 }\n' > "$gproj/deps/mathgit/index.vibe"
  "$VIBE" verify "$gproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe verify detects tamper" "1" "$rc"
  # verify recurses into transitive locks (clean tproj passes).
  "$VIBE" verify "$tproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe verify transitive exit" "0" "$rc"

  # semver constraint: a git dep with tagged releases resolves `^1.0` to the
  # highest matching tag (v1.2.0), not v2.0.0 and not the unmatched v1.3.0-only.
  srepo="$WORK/srepo"; mkdir -p "$srepo"
  ( cd "$srepo" && git init -q && git config user.email t@t && git config user.name t )
  printf 'export let v = () -> Int { 100 }\n' > "$srepo/index.vibe"
  ( cd "$srepo" && git add -A && git commit -q -m v1 && git tag v1.0.0 )
  printf 'export let v = () -> Int { 120 }\n' > "$srepo/index.vibe"
  ( cd "$srepo" && git add -A && git commit -q -m v12 && git tag v1.2.0 )
  printf 'export let v = () -> Int { 200 }\n' > "$srepo/index.vibe"
  ( cd "$srepo" && git add -A && git commit -q -m v2 && git tag v2.0.0 )
  sproj="$WORK/sproj"; mkdir -p "$sproj"
  printf 'semlib git+file://%s#^1.0\n' "$srepo" > "$sproj/vibe.deps"
  printf 'import ./deps/semlib/index.vibe { v }\nfn main with { Stdout } { Stdout::write_stream("\\{v()}\\n") }\n' > "$sproj/app.vibex"
  "$VIBE" fetch "$sproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch semver exit" "0" "$rc"
  check "vibe fetch ^1.0 picks v1.2.0" "120" "$(run_number "$sproj/app.vibex")"
  # An unsatisfiable constraint fails clearly.
  printf 'semlib git+file://%s#^9.0\n' "$srepo" > "$sproj/vibe.deps"
  "$VIBE" fetch "$sproj" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch unsat constraint fails" "1" "$rc"
else
  echo "info: git not available; skipping git+ fetch assertions"
fi

# add: `vibe add` appends to vibe.deps and fetches in one step
aproj="$WORK/aproj"; mkdir -p "$aproj"
printf 'export let inc = (x: Int) -> Int { x + 1 }\n' > "$WORK/inclib.vibe"
"$VIBE" add inclib "file://$WORK/inclib.vibe" "$aproj" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe add exit" "0" "$rc"
check "vibe add wrote manifest + lock" "yes" "$([ -s "$aproj/vibe.deps" ] && [ -s "$aproj/vibe.lock" ] && echo yes || echo no)"
printf 'import ./deps/inclib.vibe { inc }\nfn main with { Stdout } { Stdout::write_stream("\\{inc(41)}\\n") }\n' > "$aproj/app.vibex"
check "vibe run added dep" "42" "$(run_number "$aproj/app.vibex")"

# new: scaffold a project and run it
"$VIBE" new "$WORK/scaffold" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe new exit" "0" "$rc"
check "vibe new scaffolds main + deps" "yes" "$([ -s "$WORK/scaffold/main.vibex" ] && [ -f "$WORK/scaffold/vibe.deps" ] && echo yes || echo no)"
check "vibe run scaffold" "42" "$(run_number "$WORK/scaffold/main.vibex")"

echo "[test] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
