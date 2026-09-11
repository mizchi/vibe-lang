#!/usr/bin/env bash
# The launcher's project-root and build-directory contract (#2675,
# docs/toolchain-layout.md), measured on scratch projects:
#
#   * `vibe new` writes main.vibex, a root index.vpkg and .gitignore, and the
#     header it writes is the formatter's canonical shape;
#   * `vibe root` is the OUTERMOST index.vpkg walking up from the invoking
#     directory, does not cross a `.git` boundary, and falls back to the
#     invoking directory when there is no marker;
#   * a verb run from a subdirectory compiles the root-relative path against
#     ONE cache at the root: the artifact lands in <root>/.vibe/build/, the
#     subdirectory gets nothing, no `_build/` appears anywhere, and a `-o`
#     path is still relative to where the user stood;
#   * the compiled program itself runs from the invoking directory (its own
#     relative file reads do not move because of where the cache lives);
#   * `vibe clean` removes .vibe/build and `--all` the store as well;
#   * the launcher leaves nothing behind in the OS temp dir.
#
# Every assertion compares an exact string or path, so a regression in any of
# those fails here rather than in a user's project. Measured before the
# change: the same commands wrote `_build/vibe_selfhost_*` into whichever
# directory the user stood in.
#
#   VIBE_ROOT_TEST_STAGE2=<path>  which compiler answers (AGENTS.md, "Which
#                                 compiler answered?"); otherwise
#                                 scripts/resolve_stage2.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A gate must not inherit its environment (AGENTS.md, #2252): every variable
# below changes where the launcher looks or writes.
unset VIBE_LIB VIBE_BUILD_CACHE_DIR VIBE_BUILD_DIR VIBE_INVOKE_DIR VIBE_TEST_CACHE VIBE_CACHE VIBE_TOOLCHAIN || true

. "$ROOT_DIR/scripts/resolve_stage2.sh"
compiler="$(cd "$ROOT_DIR" && resolve_stage2 vibe-root "${VIBE_ROOT_TEST_STAGE2:-}")" || exit 1
case "$compiler" in
  /*) ;;
  *) compiler="$ROOT_DIR/$compiler" ;;
esac
[ -s "$compiler" ] || { echo "[vibe-root] FAIL: compiler wasm not found: $compiler" >&2; exit 1; }

runner="${VIBE_RUNNER:-$ROOT_DIR/bin/viberun}"
[ -x "$runner" ] || { echo "[vibe-root] FAIL: runner not executable: $runner (build runtime/viberun first)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-root-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/home" "$WORK/tmp"
export VIBE_HOME="$WORK/home"
export VIBE_CLI_WASM="$compiler"
export VIBE_RUNNER="$runner"
# The launcher's scratch files go through `mktemp -t`, which honors TMPDIR:
# point it at a directory of our own so "nothing left behind" is checkable.
export TMPDIR="$WORK/tmp"
V="$ROOT_DIR/runtime/vibe"

fail() { echo "[vibe-root] FAIL: $*" >&2; exit 1; }
pass() { echo "[vibe-root] ok: $*"; }
vibe() { bash "$V" "$@"; }

# --- 1. the scaffold -------------------------------------------------------
( cd "$WORK" && vibe new app >/dev/null ) || fail "vibe new failed"
app="$WORK/app"
[ -s "$app/main.vibex" ] || fail "vibe new wrote no main.vibex"
[ -s "$app/index.vpkg" ] || fail "vibe new wrote no root index.vpkg"
grep -qx 'name = @local/app' "$app/index.vpkg" || fail "the scaffold's package name is not @local/app: $(sed -n 1p "$app/index.vpkg")"
[ -s "$app/.gitignore" ] && grep -qx '\.vibe/' "$app/.gitignore" || fail "vibe new wrote no .gitignore ignoring .vibe/"
[ ! -e "$app/vibe.deps" ] || fail "vibe new still writes vibe.deps"
( cd "$app" && vibe fmt --check index.vpkg >/dev/null 2>&1 ) || fail "the scaffold's index.vpkg is not in the formatter's canonical shape"
pass "vibe new writes main.vibex, a canonical root index.vpkg (@local/app) and .gitignore"

# --- 2. the root rule --------------------------------------------------------
mkdir -p "$app/sub" "$app/lib/@x/y/deep" "$app/vendor/inner/.git" "$app/vendor/inner/deep" "$WORK/loose/sub"
printf 'name = @x/y\nversion = 0.1.0\ndescription =\n  #|nested package\ndeps = {}\n\ngenerated_hash =\n' > "$app/lib/@x/y/index.vpkg"
printf 'name = @local/inner\nversion = 0.1.0\ndescription =\n  #|checked out inside app\ndeps = {}\n\ngenerated_hash =\n' > "$app/vendor/inner/index.vpkg"

got="$(cd "$app/sub" && vibe root)"
[ "$got" = "$app" ] || fail "vibe root from a subdirectory: expected $app, got $got"
got="$(cd "$app/lib/@x/y/deep" && vibe root)"
[ "$got" = "$app" ] || fail "vibe root inside a nested package: expected the OUTERMOST index.vpkg ($app), got $got"
got="$(cd "$app/vendor/inner/deep" && vibe root)"
[ "$got" = "$app/vendor/inner" ] || fail "vibe root must not cross a .git boundary: expected $app/vendor/inner, got $got"
got="$(cd "$WORK/loose/sub" && vibe root)"
[ "$got" = "$WORK/loose/sub" ] || fail "vibe root with no index.vpkg in sight: expected the invoking directory, got $got"
( cd "$app" && vibe root extra >/dev/null 2>&1 ) && fail "vibe root accepted an argument"
pass "vibe root: outermost index.vpkg, not across .git, else the invoking directory"

# --- 3. a verb from a subdirectory ------------------------------------------
printf 'export fn answer() -> Int {\n  42\n}\n' > "$app/util.vibe"
printf 'import ../util.vibe { answer }\nfn main allows Console + Fs {\n  println("\\{answer()} \\{Fs::read_file("data.txt")}")\n}\n' > "$app/sub/deep.vibex"
printf 'from-sub' > "$app/sub/data.txt"
printf 'from-root' > "$app/data.txt"

got="$(cd "$app/sub" && vibe run deep.vibex 2>&1)" || fail "vibe run from a subdirectory failed: $got"
[ "$got" = "42 from-sub" ] || fail "the compiled program must run from the invoking directory: expected '42 from-sub', got '$got'"
[ -s "$app/.vibe/build/run/deep.wasm" ] || fail "vibe run left no artifact at <root>/.vibe/build/run/deep.wasm"
[ ! -e "$app/sub/.vibe" ] || fail "vibe run from a subdirectory created $app/sub/.vibe"
[ ! -e "$app/sub/_build" ] && [ ! -e "$app/_build" ] || fail "vibe run wrote a _build/ directory (the compiler cache must live under .vibe/build/cache)"
n_cache="$(find "$app/.vibe/build/cache" -maxdepth 1 -name 'vibe_*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_cache" -gt 0 ] || fail "the compiler cache did not land under <root>/.vibe/build/cache/"
pass "vibe run from sub/: artifact and cache at the root, program runs from sub/"

got="$(cd "$app/sub" && vibe build deep.vibex 2>&1)" || fail "vibe build without -o failed: $got"
[ "$got" = "compiled sub/deep.vibex -> .vibe/build/out/deep.wasm" ] || fail "vibe build without -o: unexpected report: $got"
[ -s "$app/.vibe/build/out/deep.wasm" ] || fail "vibe build without -o left no artifact under .vibe/build/out/"
[ ! -e "$app/sub/deep.wasm" ] || fail "vibe build without -o wrote next to the source"
( cd "$app/sub" && vibe build deep.vibex -o out.wasm >/dev/null 2>&1 ) || fail "vibe build -o from a subdirectory failed"
[ -s "$app/sub/out.wasm" ] || fail "a relative -o must resolve against the invoking directory: $app/sub/out.wasm is missing"
[ ! -e "$app/out.wasm" ] || fail "a relative -o landed at the project root instead of the invoking directory"
pass "vibe build: default output under .vibe/build/out, -o relative to where the user stood"

# --- 4. vibe test: artifact mirrors the source path, program runs from cwd --
printf 'test "reads from the invoking directory" allows Fs {\n  assert_eq(Fs::read_file("data.txt"), "from-sub")\n}\n' > "$app/sub/cwd_test.vibe"
got="$(cd "$app/sub" && vibe test cwd_test.vibe 2>&1)" || fail "vibe test from a subdirectory failed: $got"
[ -s "$app/.vibe/build/test/sub/cwd_test.wasm" ] || fail "vibe test left no artifact at <root>/.vibe/build/test/sub/cwd_test.wasm"
[ ! -e "$app/sub/.vibe" ] || fail "vibe test from a subdirectory created $app/sub/.vibe"
pass "vibe test from sub/: artifact under .vibe/build/test/sub/, test reads from sub/"

# --- 5. vibe clean ----------------------------------------------------------
mkdir -p "$app/.vibe/store/@x/y"
got="$(cd "$app/sub" && vibe clean)"
[ "$got" = "cleaned: .vibe/build" ] || fail "vibe clean: unexpected report: $got"
[ ! -e "$app/.vibe/build" ] || fail "vibe clean left .vibe/build"
[ -d "$app/.vibe/store" ] || fail "vibe clean removed the store without --all"
got="$(cd "$app" && vibe clean --all)"
[ "$got" = "cleaned: .vibe/store" ] || fail "vibe clean --all: unexpected report: $got"
[ ! -e "$app/.vibe/store" ] || fail "vibe clean --all left .vibe/store"
got="$(cd "$app" && vibe clean)"
[ "$got" = "nothing to clean under $app" ] || fail "vibe clean on a clean project: unexpected report: $got"
( cd "$app" && vibe clean --bogus >/dev/null 2>&1 ) && fail "vibe clean accepted an unknown flag"
pass "vibe clean removes .vibe/build, --all the store too"

# --- 6. nothing left in the OS temp dir -------------------------------------
leftover="$(find "$WORK/tmp" -mindepth 1 | wc -l | tr -d ' ')"
[ "$leftover" = "0" ] || fail "the launcher left $leftover entr(ies) under TMPDIR: $(ls "$WORK/tmp" | head -5 | tr '\n' ' ')"
pass "no scratch left under TMPDIR"

echo "[vibe-root] ok (compiler: $compiler)"
