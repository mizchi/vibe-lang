#!/usr/bin/env bash
# Integration test for the `vibe` install slice (docs/install.md):
# the viberun runner's vibe::* host imports, the installer, the launcher's
# run/compile/check/test subcommands, the install-time .cwasm, and the compile
# diagnostic sidecar. Runs against a throwaway VIBE_HOME so it never touches a
# real install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
# Install the current checkout's distributable CLI, not the older bootstrap
# seed. A language or contract grammar increment can make HEAD's stdlib
# intentionally unreadable by that seed before the next independent bootstrap
# bump; pairing the old compiler with the new stdlib would test an invalid
# toolchain and fail during the installer's hash verification. CI may supply a
# CLI it has already built; standalone runs use the canonical distribution
# build (including its content-addressed cache).
install_cli_wasm="${VIBE_INSTALL_TEST_CLI_WASM:-}"
if [ -z "$install_cli_wasm" ]; then
  echo "[test] building current distributable CLI for install"
  install_cli_wasm="$(bash scripts/build_cli_wasm.sh "$WORK/vibe-cli.wasm")"
fi
[ -s "$install_cli_wasm" ] || { echo "FAIL: current distributable CLI was not built" >&2; exit 1; }
bash install/install.sh \
  --cli-wasm "$install_cli_wasm" \
  >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "FAIL: launcher not installed" >&2; exit 1; }
# Toolchain layout (#755, #2677): the AOT artifact and the stdlib live under
# toolchains/<name>/lib; the shared $VIBE_HOME/lib is for `vibe pkg install`
# only (docs/install.md "Install layout").
tc_a="$VIBE_HOME/toolchains/main"
[ -f "$tc_a/lib/vibe-cli.cwasm" ] || { echo "FAIL: .cwasm not generated" >&2; exit 1; }
[ -f "$VIBE_HOME/toolchain" ] || { echo "FAIL: default toolchain file not written" >&2; exit 1; }
[ -f "$tc_a/lib/@vibe/core/index.vpkg" ] || { echo "FAIL: stdlib @vibe/core not materialized in the toolchain" >&2; exit 1; }
[ ! -e "$VIBE_HOME/lib/@vibe" ] || { echo "FAIL: the stdlib landed in the shared \$VIBE_HOME/lib (must be per toolchain, #2677)" >&2; exit 1; }
# @vibe/wit_runtime is user-facing (#1324): docs/effect-wit-mapping.md tells
# users to import it for a WIT-facing fallible export, so an installed
# toolchain that lacks it makes documented code fail to resolve.
[ -f "$tc_a/lib/@vibe/wit_runtime/index.vpkg" ] || { echo "FAIL: stdlib @vibe/wit_runtime not materialized" >&2; exit 1; }
# @vibe/builtin is user-facing (#1949): chapter-01's first import form is
# `import @vibe/console { println }`. A fresh install must ship it.
[ -f "$tc_a/lib/@vibe/builtin/index.vpkg" ] || { echo "FAIL: stdlib @vibe/builtin not materialized" >&2; exit 1; }
[ -f "$tc_a/manifest.json" ] || { echo "FAIL: manifest.json not written" >&2; exit 1; }
echo "ok: install produced launcher + .cwasm + default toolchain + per-toolchain stdlib + manifest"
pass=$((pass + 1))

proj="$WORK/proj"
mkdir -p "$proj"
printf 'fn main allows Stdout { Stdout::write_stream("42\\n") }\n' > "$proj/hello.vibex"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$proj/lib.vibe"
printf 'import ./lib.vibe { add }\nfn main allows Stdout { Stdout::write_stream("\\{add(20, 22)}\\n") }\n' > "$proj/app.vibex"
printf 'fn main allows () { let _ = nope + 1; () }\n' > "$proj/bad.vibex"
printf 'test "ok" {\n  assert_eq(2 + 2, 4)\n}\n' > "$proj/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(2 + 2, 5)\n}\n' > "$proj/fail_test.vibe"

# run: single file
check "vibe run hello" "42" "$(run_number "$proj/hello.vibex")"
# run: multi-file import resolution
check "vibe run app (import)" "42" "$(run_number "$proj/app.vibex")"

# #1949: chapter-01 prelude import must work from a temp project with only
# the installed toolchain. cd so repo lib/ is not the workspace lib, and
# drop an inherited VIBE_LIB so resolution is the launcher's own default:
# the toolchain's stdlib, then the shared $VIBE_HOME/lib (#2677).
printf 'import @vibe/console {\n  println\n}\nfn main allows Console {\n  println("42")\n}\n' > "$proj/prelude_hello.vibex"
(
  cd "$proj"
  unset VIBE_LIB || true
  check "vibe run prelude import (no repo lib/)" "42" "$(run_number "$proj/prelude_hello.vibex")"
)
# #2675 (docs/install.md): everything the toolchain generates lands
# under <root>/.vibe/build/. $proj has no index.vpkg, so the run above (cwd =
# $proj) makes $proj its own root; the compiled program and the compiler's
# cache must be there, and no `_build/` may appear anywhere in the project.
check "vibe run artifact under .vibe/build/run" "yes" "$([ -s "$proj/.vibe/build/run/prelude_hello.wasm" ] && echo yes || echo no)"
check "compiler cache under .vibe/build/cache" "yes" "$([ -n "$(find "$proj/.vibe/build/cache" -maxdepth 1 -name 'vibe_*' 2>/dev/null | head -1)" ] && echo yes || echo no)"
check "no _build/ in the project" "yes" "$([ ! -e "$proj/_build" ] && echo yes || echo no)"
# `vibe root` finds the scaffold's index.vpkg from a subdirectory.
"$VIBE" new "$WORK/scaf" >/dev/null 2>&1 || true
mkdir -p "$WORK/scaf/sub"
check "vibe root from a subdirectory of a scaffold" "$(cd "$WORK/scaf" && pwd -P)" "$(cd "$WORK/scaf/sub" && "$VIBE" root 2>/dev/null || true)"

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

# #1567 slice 1 + its review (Codex P2): `vibe check` prefixes each sidecar line
# with `error: ` so a multi-error report stays one-diagnostic-per-line and
# grep-able. A single diagnostic can still span several LINES, though --
# checker_effects.vibe appends a `hint: ...` continuation to an effect row
# mismatch -- so prefixing every line would report ONE diagnostic as TWO. This
# pins the distinction: exactly one `error: ` line, with the hint present and
# indented under it rather than counted as its own error.
printf 'fn leaky() -> String {\n  Env::get("HOME")\n}\n\nfn main {\n  let _ = leaky()\n  ()\n}\n' > "$proj/hint.vibe"
hint_diag="$("$VIBE" check "$proj/hint.vibe" 2>&1 || true)"
if echo "$hint_diag" | grep -q "effect row mismatch"; then
  check "vibe check counts a hint as part of its diagnostic" \
    "1" "$(echo "$hint_diag" | grep -c '^error: ')"
  check "vibe check still shows the hint" \
    "yes" "$(echo "$hint_diag" | grep -q 'hint: ' && echo yes || echo no)"
else
  echo "info: compiler did not emit the effect row mismatch hint (seed build); skipping continuation-line assertion"
fi

# #1567 slice 2: the `vibe check` REPORTING CONTRACT, pinned as a whole. The
# point of the unification is that a caller can judge a file without knowing
# which lane answered, so all three properties have to hold together:
#   diagnostics on STDOUT (not stderr) / clean = EMPTY output / exit 1 when
#   anything is reported.
# Splitting stdout from stderr here is deliberate -- the old contract printed
# diagnostics to stderr and `ok: <file>` to stdout, so a test that merges the
# two (`2>&1`) cannot tell the two contracts apart.
chk_stdout="$("$VIBE" check "$proj/bad.vibex" 2>/dev/null || true)"
check "vibe check writes diagnostics to stdout" \
  "yes" "$(echo "$chk_stdout" | grep -q '^error: ' && echo yes || echo no)"
clean_stdout="$("$VIBE" check "$proj/app.vibex" 2>/dev/null || true)"
check "vibe check is silent on a clean file" "" "$clean_stdout"

# `--single-file` is what makes the second verb (`vibe diagnostics`)
# unnecessary, so pin the thing that actually distinguishes the two modes:
# app.vibex imports lib.vibe, so it is CLEAN with FS import resolution and
# reports an unknown name WITHOUT it. Same file, same verb, one flag.
sf_out="$("$VIBE" check --single-file "$proj/app.vibex" 2>/dev/null || true)"
"$VIBE" check --single-file "$proj/app.vibex" >/dev/null 2>&1 && rc=0 || rc=$?
if echo "$sf_out" | grep -q 'unknown name'; then
  check "vibe check --single-file does not resolve imports" "1" "$rc"
  check "vibe check (no flag) does resolve them" "" "$clean_stdout"
else
  echo "info: compiler did not report an unresolved import in single-file mode (seed build); skipping --single-file assertion"
fi
sf_clean="$("$VIBE" check --single-file "$proj/lib.vibe" 2>/dev/null || true)"
check "vibe check --single-file is silent on a clean file" "" "$sf_clean"

# The #1129 soft passes (unused import / unbound non-Unit return) are WARNINGS:
# advisory, documented as never affecting the exit code. They come back in the
# same report as the errors, so the two modes have to agree on splitting them
# out -- otherwise `--single-file` calls a file broken that the import-resolving
# lane calls clean, which is the very disagreement #1567 removes.
printf 'import ./lib.vibe { add }\n\nexport let main = () -> Int { 42 }\n' > "$proj/warnonly.vibe"
warn_stdout="$("$VIBE" check --single-file "$proj/warnonly.vibe" 2>/dev/null || true)"
warn_stderr="$("$VIBE" check --single-file "$proj/warnonly.vibe" 2>&1 >/dev/null || true)"
"$VIBE" check --single-file "$proj/warnonly.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
if echo "$warn_stderr" | grep -q 'warning: '; then
  check "vibe check --single-file exits 0 on warnings alone" "0" "$rc"
  check "vibe check --single-file keeps warnings off stdout" "" "$warn_stdout"
  check "vibe check --single-file never labels a warning an error" \
    "0" "$(echo "$warn_stdout" | grep -c '^error: ')"
  "$VIBE" check "$proj/warnonly.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe check (import lane) agrees the same file is clean" "0" "$rc"
  "$VIBE" check --single-file --json "$proj/warnonly.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe check --json exits 0 on warnings alone" "0" "$rc"
else
  echo "info: compiler did not emit an unused-import warning (seed build); skipping warning-split assertion"
fi

# --json rides the compiler's own structured emitter, so it is only available
# in single-file mode; without the flag the launcher must say so instead of
# emitting something JSON-shaped but rangeless.
json_out="$("$VIBE" check --single-file --json "$proj/bad.vibex" 2>/dev/null || true)"
check "vibe check --single-file --json emits a JSON array" \
  "yes" "$(echo "$json_out" | grep -q '^\[{' && echo yes || echo no)"
json_clean="$("$VIBE" check --single-file --json "$proj/lib.vibe" 2>/dev/null || true)"
check "vibe check --json emits [] for a clean file" "[]" "$json_clean"
"$VIBE" check --single-file --json "$proj/lib.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe check --json exits 0 for a clean file" "0" "$rc"
"$VIBE" check --json "$proj/lib.vibe" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe check --json without --single-file is refused" "1" "$rc"

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

# Dependencies (#2676, docs/install.md "Dependencies"): `vibe add
# <source-spec>` fetches a package from a git source into the project's
# `.vibe/store/` and pins it in the root index.vpkg (version, content hash,
# commit-pinned source); `vibe fetch` restores the store from those pins on a
# fresh clone, from the cache or from the source. Hermetic file:// repositories
# stand in for GitHub.
run_number_in() { # run_number_in <dir> <file>
  ( cd "$1" && "$VIBE" run "$2" 2>/dev/null ) | grep -oE '[0-9]+' | head -1
}
git_commit_all() { # git_commit_all <dir> <message>
  ( cd "$1" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m "$2" )
}
if command -v git >/dev/null 2>&1; then
  dep_repo="$WORK/dep_repo"
  mkdir -p "$dep_repo/packages/@acme/mathx"
  printf 'name = @acme/mathx\nversion = 1.0.0\ndescription =\n  #|fixture\ndeps = {}\n\ngenerated_hash =\n\nfn triple(x: Int) -> Int\n' > "$dep_repo/packages/@acme/mathx/index.vpkg"
  printf 'export fn triple(x: Int) -> Int {\n  x * 3\n}\n' > "$dep_repo/packages/@acme/mathx/impl.vibe"
  ( cd "$dep_repo" && git init -q )
  git_commit_all "$dep_repo" mathx
  ( cd "$dep_repo" && git tag v1.0.0 )
  dep_commit="$(git -C "$dep_repo" rev-parse HEAD)"
  dep_spec="git:file://$dep_repo@v1.0.0#packages/@acme/mathx"

  dproj="$WORK/dproj"
  "$VIBE" new "$dproj" >/dev/null 2>&1
  printf 'import @acme/mathx { triple }\nfn main allows Stdout { Stdout::write_stream("\\{triple(14)}\\n") }\n' > "$dproj/main.vibex"
  ( cd "$dproj" && "$VIBE" add "$dep_spec" ) > "$WORK/add.log" 2>&1 && rc=0 || rc=$?
  check "vibe add exit" "0" "$rc"
  check "vibe add installs into .vibe/store" "yes" "$([ -s "$dproj/.vibe/store/@acme/mathx/index.vpkg" ] && echo yes || echo no)"
  check "vibe add pins version, hash and the commit-pinned source" "yes" \
    "$(grep -qE '^require @acme/mathx 1\.0\.0 = #pkg:sha1:[0-9a-f]{40} from git:' "$dproj/index.vpkg" \
       && grep -qF "from git:file://$dep_repo@$dep_commit#packages/@acme/mathx" "$dproj/index.vpkg" && echo yes || echo no)"
  check "vibe add declares the dependency" "yes" "$(grep -qx '  @acme/mathx : 1.0.0' "$dproj/index.vpkg" && echo yes || echo no)"
  ( cd "$dproj" && "$VIBE" fmt --check index.vpkg ) >/dev/null 2>&1 && rc=0 || rc=$?
  check "the pin line round-trips through vibe fmt --check" "0" "$rc"
  check "vibe run resolves the store package through the manifest pin" "42" "$(run_number_in "$dproj" main.vibex)"
  check "vibe add writes only the manifest and the store" "yes" \
    "$([ "$(ls -A "$dproj" | LC_ALL=C sort | tr '\n' ' ')" = ".gitignore .vibe index.vpkg main.vibex " ] && echo yes || echo no)"

  # A fresh clone carries the manifest and no store (`.vibe/` is ignored):
  # `vibe fetch` restores it, first from the cache `vibe add` populated, then
  # from the pinned source once the cache is wiped.
  ( cd "$dproj" && git init -q )
  git_commit_all "$dproj" app
  clone1="$WORK/clone1"
  git clone -q "$dproj" "$clone1"
  check "a fresh clone has no store" "yes" "$([ ! -e "$clone1/.vibe" ] && echo yes || echo no)"
  ( cd "$clone1" && "$VIBE" fetch ) > "$WORK/fetch1.log" 2>&1 && rc=0 || rc=$?
  check "vibe fetch from the cache exit" "0" "$rc"
  check "vibe fetch from the cache restores a running store" "42" "$(run_number_in "$clone1" main.vibex)"
  rm -rf "$VIBE_HOME/cache/pkg"
  clone2="$WORK/clone2"
  git clone -q "$dproj" "$clone2"
  ( cd "$clone2" && "$VIBE" fetch ) > "$WORK/fetch2.log" 2>&1 && rc=0 || rc=$?
  check "vibe fetch from the pinned source exit" "0" "$rc"
  check "vibe fetch from the pinned source restores a running store" "42" "$(run_number_in "$clone2" main.vibex)"

  # A store copy that no longer hashes to its pin is refused by the build and
  # replaced by `vibe fetch`; a source that does not hash to the pin is
  # refused before anything is installed.
  printf 'export fn triple(x: Int) -> Int {\n  x * 999\n}\n' > "$clone1/.vibe/store/@acme/mathx/impl.vibe"
  ( cd "$clone1" && "$VIBE" run main.vibex ) > "$WORK/tamper.log" 2>&1 && rc=0 || rc=$?
  check "a tampered store copy is refused by the build" "yes" "$([ "$rc" != 0 ] && grep -q 'pin mismatch' "$WORK/tamper.log" && echo yes || echo no)"
  ( cd "$clone1" && "$VIBE" fetch ) >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe fetch replaces the tampered copy" "0" "$rc"
  check "the replaced copy runs" "42" "$(run_number_in "$clone1" main.vibex)"
  clone3="$WORK/clone3"
  git clone -q "$dproj" "$clone3"
  sed -i.bak -E 's/#pkg:sha1:[0-9a-f]{40}/#pkg:sha1:0000000000000000000000000000000000000000/' "$clone3/index.vpkg"
  rm -f "$clone3/index.vpkg.bak"
  ( cd "$clone3" && "$VIBE" fetch ) > "$WORK/fetch3.log" 2>&1 && rc=0 || rc=$?
  check "vibe fetch refuses a source that does not hash to the pin" "yes" "$([ "$rc" != 0 ] && grep -q 'hash mismatch' "$WORK/fetch3.log" && echo yes || echo no)"
  check "a refused fetch installs nothing" "yes" "$([ ! -e "$clone3/.vibe/store/@acme/mathx" ] && echo yes || echo no)"

  # A package that does not compile cannot be hashed, and the compiler's own
  # diagnostic reaches stderr: `cat "$x.diag" 2>/dev/null >&2` sent the
  # message to /dev/null (the redirections apply left to right), so every
  # `vibe hash` / `vibe add` / `vibe pkg` failure showed only the generic line.
  mkdir -p "$WORK/badpkg"
  printf 'name = @acme/bad\nversion = 1.0.0\ndescription =\n  #|fixture\ndeps = {}\n\ngenerated_hash =\n\nfn broken(x: Int) -> Int\n' > "$WORK/badpkg/index.vpkg"
  printf 'export fn broken(x: Int) -> Int {\n  x +\n}\n' > "$WORK/badpkg/impl.vibe"
  ( cd "$WORK" && "$VIBE" hash badpkg ) > "$WORK/hash_bad.out" 2> "$WORK/hash_bad.err" && rc=0 || rc=$?
  check "vibe hash on a package that does not compile fails" "yes" "$([ "$rc" != 0 ] && echo yes || echo no)"
  check "vibe hash prints the compiler's diagnostic, not only the generic line" "yes" "$(grep -q 'unexpected token' "$WORK/hash_bad.err" && echo yes || echo no)"

  # `@local` (what `vibe new` scaffolds) is not a published name.
  ( cd "$dproj" && "$VIBE" pkg publish . ) > "$WORK/publish_local.log" 2>&1 && rc=0 || rc=$?
  check "vibe pkg publish refuses the @local scope" "yes" "$([ "$rc" != 0 ] && grep -q '@local' "$WORK/publish_local.log" && echo yes || echo no)"

  # A semver constraint ref resolves to the highest matching tag (v1.2.0 for
  # ^1.0: not v2.0.0), and the pin records that release's version and commit.
  sem_repo="$WORK/sem_repo"
  mkdir -p "$sem_repo/packages/@acme/semlib"
  ( cd "$sem_repo" && git init -q )
  for sv in 1.0.0:100 1.2.0:120 2.0.0:200; do
    printf 'name = @acme/semlib\nversion = %s\ndescription =\n  #|fixture\ndeps = {}\n\ngenerated_hash =\n\nfn v() -> Int\n' "${sv%%:*}" > "$sem_repo/packages/@acme/semlib/index.vpkg"
    printf 'export fn v() -> Int {\n  %s\n}\n' "${sv##*:}" > "$sem_repo/packages/@acme/semlib/impl.vibe"
    git_commit_all "$sem_repo" "v${sv%%:*}"
    ( cd "$sem_repo" && git tag "v${sv%%:*}" )
  done
  sproj="$WORK/sproj"
  "$VIBE" new "$sproj" >/dev/null 2>&1
  printf 'import @acme/semlib { v }\nfn main allows Stdout { Stdout::write_stream("\\{v()}\\n") }\n' > "$sproj/main.vibex"
  ( cd "$sproj" && "$VIBE" add "git:file://$sem_repo@^1.0#packages/@acme/semlib" ) > "$WORK/add_sem.log" 2>&1 && rc=0 || rc=$?
  check "vibe add ^1.0 exit" "0" "$rc"
  check "vibe add ^1.0 picks v1.2.0" "120" "$(run_number_in "$sproj" main.vibex)"
  check "vibe add ^1.0 pins the resolved release" "yes" "$(grep -qE '^require @acme/semlib 1\.2\.0 = #pkg:sha1:[0-9a-f]{40} from git:.*@[0-9a-f]{40}#packages/@acme/semlib$' "$sproj/index.vpkg" && echo yes || echo no)"
  ( cd "$sproj" && "$VIBE" add "git:file://$sem_repo@^9.0#packages/@acme/semlib" ) >/dev/null 2>&1 && rc=0 || rc=$?
  check "vibe add with an unsatisfiable constraint fails" "yes" "$([ "$rc" != 0 ] && echo yes || echo no)"

  # Transitive: the project pins @acme/mid, whose own index.vpkg pins
  # @acme/base; `vibe add` follows that pin, and so does `vibe fetch` on a
  # fresh clone.
  base_repo="$WORK/base_repo"
  mkdir -p "$base_repo/packages/@acme/base"
  printf 'name = @acme/base\nversion = 1.0.0\ndescription =\n  #|fixture\ndeps = {}\n\ngenerated_hash =\n\nfn base(x: Int) -> Int\n' > "$base_repo/packages/@acme/base/index.vpkg"
  printf 'export fn base(x: Int) -> Int {\n  x * 10\n}\n' > "$base_repo/packages/@acme/base/impl.vibe"
  ( cd "$base_repo" && git init -q )
  git_commit_all "$base_repo" base
  ( cd "$base_repo" && git tag v1.0.0 )
  # The mid package is authored the way a user would: `vibe add` its
  # dependency in its own checkout, so its index.vpkg carries the pin.
  mid_repo="$WORK/mid_repo"
  mkdir -p "$mid_repo/packages/@acme/mid"
  printf 'name = @acme/mid\nversion = 1.0.0\ndescription =\n  #|fixture\ndeps = {}\n\ngenerated_hash =\n\nfn mid(x: Int) -> Int\n' > "$mid_repo/packages/@acme/mid/index.vpkg"
  printf 'import @acme/base { base }\n\nexport fn mid(x: Int) -> Int {\n  base(x) + 2\n}\n' > "$mid_repo/packages/@acme/mid/impl.vibe"
  ( cd "$mid_repo/packages/@acme/mid" && "$VIBE" add "git:file://$base_repo@v1.0.0#packages/@acme/base" ) > "$WORK/add_base.log" 2>&1 && rc=0 || rc=$?
  check "vibe add inside a package checkout pins in that package's index.vpkg" "yes" "$([ "$rc" = 0 ] && grep -q '^require @acme/base 1.0.0 = #pkg:sha1:' "$mid_repo/packages/@acme/mid/index.vpkg" && echo yes || echo no)"
  rm -rf "$mid_repo/packages/@acme/mid/.vibe"
  ( cd "$mid_repo" && git init -q )
  git_commit_all "$mid_repo" mid
  tproj="$WORK/tproj"
  "$VIBE" new "$tproj" >/dev/null 2>&1
  printf 'import @acme/mid { mid }\nfn main allows Stdout { Stdout::write_stream("\\{mid(4)}\\n") }\n' > "$tproj/main.vibex"
  ( cd "$tproj" && "$VIBE" add "git:file://$mid_repo@HEAD#packages/@acme/mid" ) > "$WORK/add_mid.log" 2>&1 && rc=0 || rc=$?
  check "vibe add of a package with its own pin exit" "0" "$rc"
  check "vibe add follows the added package's pins" "yes" "$([ -s "$tproj/.vibe/store/@acme/base/index.vpkg" ] && echo yes || echo no)"
  check "vibe run through a transitive store dependency" "42" "$(run_number_in "$tproj" main.vibex)"
  ( cd "$tproj" && git init -q )
  git_commit_all "$tproj" app
  tclone="$WORK/tclone"
  git clone -q "$tproj" "$tclone"
  ( cd "$tclone" && "$VIBE" fetch ) > "$WORK/fetch_t.log" 2>&1 && rc=0 || rc=$?
  check "vibe fetch follows transitive pins on a fresh clone" "42" "$([ "$rc" = 0 ] && run_number_in "$tclone" main.vibex)"
else
  echo "info: git not available; skipping the dependency assertions"
fi

# new: scaffold a project and run it
"$VIBE" new "$WORK/scaffold" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe new exit" "0" "$rc"
# #2675: the scaffold is exactly main.vibex + a root index.vpkg (the project
# marker and manifest) + .gitignore.
check "vibe new scaffolds main + index.vpkg + .gitignore" "yes" "$([ -s "$WORK/scaffold/main.vibex" ] && grep -qx 'name = @local/scaffold' "$WORK/scaffold/index.vpkg" && grep -qx '.vibe/' "$WORK/scaffold/.gitignore" && [ "$(ls -A "$WORK/scaffold" | LC_ALL=C sort | tr '\n' ' ')" = ".gitignore index.vpkg main.vibex " ] && echo yes || echo no)"
check "vibe run scaffold" "42" "$(run_number "$WORK/scaffold/main.vibex")"
# #2676: `--name @scope/name` names a project that will be published; anything
# else is refused before the directory is created.
"$VIBE" new --name @acme/app "$WORK/scaffold_named" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe new --name exit" "0" "$rc"
check "vibe new --name writes the given package name" "yes" "$(grep -qx 'name = @acme/app' "$WORK/scaffold_named/index.vpkg" && echo yes || echo no)"
"$VIBE" new --name bogus "$WORK/scaffold_bad" >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe new --name refuses a name that is not @scope/name" "yes" "$([ "$rc" != 0 ] && [ ! -e "$WORK/scaffold_bad" ] && echo yes || echo no)"

# Two toolchains in one home (#2677, docs/install.md "Install layout"): each
# carries its own stdlib and manifest, so installing a second one never
# touches the first's. The second install root is a minimal copy of this
# checkout whose @vibe/console gains one observable function; the runner and
# the compiler wasm are reused from the first toolchain.
check "manifest.json names the toolchain" "yes" "$(grep -q '"toolchain": "main"' "$tc_a/manifest.json" && echo yes || echo no)"
manifest_version="$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$tc_a/manifest.json")"
# Capture the whole output before looking at its first line: under pipefail a
# `| head -n 1` closes the pipe while the launcher is still printing, and the
# SIGPIPE it takes fails the pipeline even when the line matched.
version_line="$("$VIBE" version 2>/dev/null | sed -n '1p')"
check "vibe version reports the manifest's version and toolchain" "yes" "$([ -n "$manifest_version" ] && printf '%s\n' "$version_line" | grep -qF "vibe $manifest_version (toolchain main" && echo yes || echo no)"
root2="$WORK/root2"
mkdir -p "$root2/install" "$root2/bootstrap" "$root2/runtime" "$root2/scripts" "$root2/lib/@vibe"
cp "$ROOT_DIR/install/install.sh" "$root2/install/"
cp "$ROOT_DIR/bootstrap/seed.json" "$root2/bootstrap/"
cp "$ROOT_DIR/runtime/vibe" "$root2/runtime/"
cp "$ROOT_DIR/scripts/vibe_pkg.sh" "$ROOT_DIR/scripts/parallel_warm_pool.sh" "$root2/scripts/"
for pkg in core ast parser builtin console wit_runtime; do
  cp -R "$ROOT_DIR/lib/@vibe/$pkg" "$root2/lib/@vibe/$pkg"
done
printf '\nfn toolchain_probe() -> Int\n' >> "$root2/lib/@vibe/console/index.vpkg"
printf 'export fn toolchain_probe() -> Int {\n  2\n}\n' > "$root2/lib/@vibe/console/toolchain_probe.vibe"
bash "$root2/install/install.sh" --__vibe-install-root "$root2" --toolchain probe \
  --runner "$tc_a/bin/viberun" --cli-wasm "$tc_a/lib/vibe-cli.wasm" --no-link --no-modify-path \
  > "$WORK/install_probe.log" 2>&1 && rc=0 || rc=$?
check "a second toolchain installs next to the first" "0" "$rc"
check "the first toolchain's stdlib is untouched by the second install" "yes" \
  "$([ ! -e "$tc_a/lib/@vibe/console/toolchain_probe.vibe" ] && ! grep -q toolchain_probe "$tc_a/lib/@vibe/console/index.vpkg" && echo yes || echo no)"
check "the first toolchain stays the default" "main" "$(cat "$VIBE_HOME/toolchain")"
printf 'import @vibe/console { toolchain_probe }\nfn main allows Stdout { Stdout::write_stream("\\{toolchain_probe()}\\n") }\n' > "$proj/probe.vibex"
check "the default toolchain does not see the second's stdlib" "yes" "$( ( cd "$proj" && "$VIBE" run probe.vibex ) >/dev/null 2>&1 && echo no || echo yes)"
check "VIBE_TOOLCHAIN=probe runs the second toolchain's stdlib" "2" "$( ( cd "$proj" && VIBE_TOOLCHAIN=probe "$VIBE" run probe.vibex 2>/dev/null ) | grep -oE '[0-9]+' | head -1)"
check "the second toolchain runs the base stdlib too" "42" "$( ( cd "$proj" && VIBE_TOOLCHAIN=probe "$VIBE" run prelude_hello.vibex 2>/dev/null ) | grep -oE '[0-9]+' | head -1)"
# vibe toolchain: list marks the default; default switches without a
# reinstall; remove refuses the default and deletes another.
list_out="$("$VIBE" toolchain list 2>/dev/null || true)"
check "vibe toolchain list marks the default" "yes" "$(printf '%s\n' "$list_out" | grep -qE '^\* main[[:space:]]' && printf '%s\n' "$list_out" | grep -qE '^  probe[[:space:]]' && echo yes || echo no)"
"$VIBE" toolchain default probe >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe toolchain default probe exit" "0" "$rc"
check "the default file now names probe" "probe" "$(cat "$VIBE_HOME/toolchain")"
check "after the switch, vibe run uses the second toolchain" "2" "$(run_number_in "$proj" probe.vibex)"
version_line="$("$VIBE" version 2>/dev/null | sed -n '1p')"
check "after the switch, vibe version reports probe" "yes" "$(printf '%s\n' "$version_line" | grep -qF '(toolchain probe' && echo yes || echo no)"
"$VIBE" toolchain remove probe >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe toolchain remove refuses the default" "yes" "$([ "$rc" != 0 ] && [ -d "$VIBE_HOME/toolchains/probe" ] && echo yes || echo no)"
"$VIBE" toolchain default main >/dev/null 2>&1 && rc=0 || rc=$?
check "switching back restores the first toolchain" "yes" "$([ "$rc" = 0 ] && ! ( cd "$proj" && "$VIBE" run probe.vibex ) >/dev/null 2>&1 && echo yes || echo no)"
"$VIBE" toolchain remove probe >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe toolchain remove deletes a non-default toolchain" "yes" "$([ "$rc" = 0 ] && [ ! -e "$VIBE_HOME/toolchains/probe" ] && echo yes || echo no)"
"$VIBE" toolchain default nope >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe toolchain default refuses an uninstalled name" "yes" "$([ "$rc" != 0 ] && [ "$(cat "$VIBE_HOME/toolchain")" = main ] && echo yes || echo no)"

# The pre-#755 flat layout is refused, by the launcher and by the installer,
# with a message naming the installer.
flat="$WORK/flat"
mkdir -p "$flat/bin" "$flat/lib"
cp "$tc_a/bin/vibe" "$flat/bin/vibe"
cp "$tc_a/bin/viberun" "$flat/bin/viberun"
cp "$tc_a/lib/vibe-cli.wasm" "$flat/lib/vibe-cli.wasm"
( env -u VIBE_HOME "$flat/bin/vibe" version ) > "$WORK/flat.out" 2>&1 && rc=0 || rc=$?
check "a flat-layout launcher is refused, naming the installer" "yes" "$([ "$rc" != 0 ] && grep -q 'install/install.sh' "$WORK/flat.out" && echo yes || echo no)"
VIBE_HOME="$flat" bash "$ROOT_DIR/install/install.sh" --__vibe-install-root "$ROOT_DIR" \
  --runner "$tc_a/bin/viberun" --cli-wasm "$tc_a/lib/vibe-cli.wasm" --no-stdlib --no-link --no-modify-path \
  > "$WORK/flat_install.out" 2>&1 && rc=0 || rc=$?
check "the installer refuses a flat-layout VIBE_HOME" "yes" "$([ "$rc" != 0 ] && grep -q 'flat' "$WORK/flat_install.out" && [ ! -e "$flat/toolchains" ] && echo yes || echo no)"

# self uninstall: --purge on a copy of the home removes everything; the plain
# form keeps the shared cache/, lib/ and log/. Last, since it removes the
# toolchain the rest of this file runs.
cp -R "$VIBE_HOME" "$WORK/home2"
VIBE_HOME="$WORK/home2" "$WORK/home2/bin/vibe" self uninstall --purge >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe self uninstall --purge exit" "0" "$rc"
check "vibe self uninstall --purge leaves nothing" "yes" "$([ ! -e "$WORK/home2/toolchains" ] && [ ! -e "$WORK/home2/bin" ] && [ ! -e "$WORK/home2/cache" ] && [ ! -e "$WORK/home2/lib" ] && echo yes || echo no)"
mkdir -p "$VIBE_HOME/lib/@keep" "$VIBE_HOME/cache/pkg"
"$VIBE" self uninstall >/dev/null 2>&1 && rc=0 || rc=$?
check "vibe self uninstall exit" "0" "$rc"
check "vibe self uninstall removes toolchains, bin, env and the default file" "yes" "$([ ! -e "$VIBE_HOME/toolchains" ] && [ ! -e "$VIBE_HOME/bin" ] && [ ! -e "$VIBE_HOME/env" ] && [ ! -e "$VIBE_HOME/toolchain" ] && echo yes || echo no)"
check "vibe self uninstall keeps cache and lib" "yes" "$([ -d "$VIBE_HOME/cache" ] && [ -d "$VIBE_HOME/lib/@keep" ] && echo yes || echo no)"

echo "[test] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
