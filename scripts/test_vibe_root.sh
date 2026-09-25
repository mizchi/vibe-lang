#!/usr/bin/env bash
# The launcher's project-root and build-directory contract (#2675,
# docs/user/getting-started/install.md "Project layout"), measured on scratch projects:
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
#                                 compiler answered?"); otherwise the
#                                 generation built for HEAD, otherwise a fresh
#                                 build_cli_wasm.sh build (what the cli-install
#                                 workflow's smoke groups use). Never the seed:
#                                 it predates the build directory and would
#                                 fail the `_build/` assertion for the wrong
#                                 reason.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A gate must not inherit its environment (AGENTS.md, #2252): every variable
# below changes where the launcher looks or writes.
unset VIBE_LIB VIBE_BUILD_CACHE_DIR VIBE_BUILD_DIR VIBE_INVOKE_DIR VIBE_TOOLCHAIN || true

compiler="${VIBE_ROOT_TEST_STAGE2:-}"
if [ -z "$compiler" ]; then
  sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    for gen in "$ROOT_DIR"/_build/selfhost/generations/*_"$sha"/; do
      [ -s "${gen}stage2.wasm" ] && { compiler="${gen}stage2.wasm"; break; }
    done
  fi
fi
if [ -z "$compiler" ]; then
  echo "[vibe-root] no generation for HEAD; building the checkout's compiler (scripts/build_cli_wasm.sh)" >&2
  compiler="$(cd "$ROOT_DIR" && bash scripts/build_cli_wasm.sh)" || { echo "[vibe-root] FAIL: build_cli_wasm.sh failed" >&2; exit 1; }
fi
case "$compiler" in
  /*) ;;
  *) compiler="$ROOT_DIR/$compiler" ;;
esac
[ -s "$compiler" ] || { echo "[vibe-root] FAIL: compiler wasm not found: $compiler" >&2; exit 1; }

# The runner: an explicit VIBE_RUNNER, the dev shim, or the cargo build the
# cli-install workflow produces; build it when none is there (as
# scripts/test_vibe_bench.sh does).
runner="${VIBE_RUNNER:-}"
if [ -z "$runner" ]; then
  for cand in "$ROOT_DIR/bin/viberun" "$ROOT_DIR/runtime/viberun/target/release/viberun"; do
    [ -x "$cand" ] && { runner="$cand"; break; }
  done
fi
if [ -z "$runner" ]; then
  command -v cargo >/dev/null 2>&1 || { echo "[vibe-root] FAIL: no viberun runner and no cargo to build one (runtime/viberun)" >&2; exit 1; }
  ( cd "$ROOT_DIR" && cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null ) \
    || { echo "[vibe-root] FAIL: cargo build of runtime/viberun failed" >&2; exit 1; }
  runner="$ROOT_DIR/runtime/viberun/target/release/viberun"
fi
[ -x "$runner" ] || { echo "[vibe-root] FAIL: runner not executable: $runner" >&2; exit 1; }

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
[ "$(ls -A "$app" | LC_ALL=C sort | tr '\n' ' ')" = ".gitignore index.vpkg main.vibex " ] || fail "vibe new must write exactly main.vibex, index.vpkg and .gitignore, got: $(ls -A "$app" | tr '\n' ' ')"
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

# --- 4b. flag shapes the ADR-0111 rewrite and the launcher must not mangle ---
# A valueless run flag before the source: the source is still rewritten to
# the root-relative path (it used to be classed as the flag's value and left
# relative to sub/, so the compiler reported an existing file as missing).
got="$(cd "$app/sub" && vibe run --alloc-site deep.vibex 2>&1)" || fail "vibe run --alloc-site from a subdirectory failed: $got"
case "$got" in *"42 from-sub"*) ;; *) fail "vibe run --alloc-site from sub/: expected the program output '42 from-sub' in: $got" ;; esac
# A trailing `--jobs` with no value is a malformed invocation: refused, never
# silently run at the default job count.
got="$(cd "$app/sub" && vibe test cwd_test.vibe --jobs 2>&1)" && fail "vibe test <file> --jobs (no value) must be refused, got exit 0: $got"
case "$got" in *"missing value after --jobs"*) ;; *) fail "vibe test <file> --jobs: expected 'missing value after --jobs' in: $got" ;; esac
pass "vibe run --alloc-site <src> rewrites the source; a trailing --jobs is refused"

# --- 4c. the grep driver flags carry PATHS, so they are rewritten too -------
# `--file-list` and `--resume-out` (#2914) name files the caller chose. From a
# subdirectory the compiler runs at the ROOT, so an unrewritten value resolves
# against the wrong directory -- silently, because the equals spellings begin
# with `-` and never reach the generic path branch at all, and `--resume-out`
# names a file that does not exist yet, which that branch skips by design
# (Codex on #2956, P2). Both spellings, because they failed for different
# reasons.
# TWO matching files, and that is not padding. The memory guard runs only
# inside `if Array::length(hits) > 0` and needs `max_typed_cost > 0`, which is
# set only AFTER a matching file is typed -- so with one match it cannot fire
# at all, and the resume assertion below would fail unconditionally rather than
# testing anything (Codex on #2956, P1). The second match is where it fires.
printf 'export fn gtarget(xs: Array[String]) -> Int {\n  Array::length(xs)\n}\n' > "$app/sub/greppable.vibe"
printf 'export fn gtarget2(ys: Array[String]) -> Int {\n  Array::length(ys)\n}\n' > "$app/sub/greppable2.vibe"
# LIST ENTRIES RESOLVE AGAINST THE PROJECT ROOT, exactly as `--list-files`
# prints them -- the output of one flag is the input of the other, and that
# round trip is the whole point of the pair. Only the list FILE's own path is
# rewritten from where the user stood.
printf 'sub/greppable.vibe\nsub/greppable2.vibe\n' > "$app/sub/mylist.txt"
got="$(cd "$app/sub" && vibe grep --file-list=./mylist.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
  || fail "vibe grep --file-list=<rel> from a subdirectory failed: $got"
case "$got" in *"greppable.vibe:2:3"*) ;; *) fail "vibe grep --file-list=<rel> from sub/: expected a match in greppable.vibe, got: $got" ;; esac
[ ! -e "$app/mylist.txt" ] || fail "vibe grep --file-list=<rel> looked for the list at the ROOT"
# The split spelling of a file that does NOT exist yet: a 1 MB budget forces
# the sweep to hand off at the SECOND match, and the index must land where the
# user stood.
( cd "$app/sub" && VIBE_GREP_MEMORY_BUDGET_MB=1 vibe grep --resume-out ./r.idx \
    --pattern 'Array::length($(x:exp))' --where '$x : Array[String]' . >/dev/null 2>&1 ) || true
if [ -e "$app/r.idx" ]; then
  fail "vibe grep --resume-out <rel> wrote the index to the ROOT ($app/r.idx), not to sub/"
fi
[ -e "$app/sub/r.idx" ] || fail "vibe grep --resume-out <rel> wrote no index at all under sub/.
A 1 MB budget must force a hand-off at the second matching file, or this case
proves nothing about where the file lands."
# A LIST ENTRY THAT DOES NOT EXIST MUST SAY SO. Unguarded this was a bare wasm
# trap -- `viberun: error while executing at wasm backtrace: <wasm function
# 6411>`, no file, no reason -- which is what the CLI-install smoke reported
# when the entries in this very test resolved against the wrong root. A
# mistyped list is the most likely way to meet this flag wrongly, so it gets
# the message that names the rule.
# A DIRECTORY entry gets its own diagnostic: it passes the existence check and
# would then fail inside Fs::read_file as a host-level EISDIR, which is the
# bare trap the guard above exists to replace.
# Its OWN directory, created here. The first version pointed at `sub/nl`,
# which this file does not create until the newline case further down, so the
# entry did not exist and the guard answered "not found" -- the right refusal
# for the wrong reason, and the case caught it only because it asserts WHICH
# diagnostic appears rather than merely that one did.
mkdir -p "$app/sub/adirentry"
printf 'sub/adirentry\n' > "$app/sub/dirlist.txt"
got="$(cd "$app/sub" && vibe grep --file-list=./dirlist.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
  && fail "a directory in a file list must fail, got exit 0: $got"
case "$got" in
  *"file-list entry is a directory"*) ;;
  *) fail "a directory entry must say so, got: $got" ;;
esac
case "$got" in
  *"wasm backtrace"*|*EISDIR*) fail "a directory entry still reached the host read: $got" ;;
  *) ;;
esac

printf 'no_such_file_here.vibe\n' > "$app/sub/badlist.txt"
got="$(cd "$app/sub" && vibe grep --file-list=./badlist.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
  && fail "vibe grep with a missing file-list entry must fail, got exit 0: $got"
case "$got" in
  *"file-list entry not found"*) ;;
  *) fail "a missing file-list entry must name itself and the rule, got: $got" ;;
esac
case "$got" in
  *"no_such_file_here.vibe"*) ;;
  *) fail "a missing file-list entry must name the FILE, got: $got" ;;
esac
case "$got" in
  *"wasm backtrace"*) fail "a missing file-list entry still trapped: $got" ;;
  *) ;;
esac
# THE LIST FILE ITSELF, mistyped and pointed at a directory. The two cases
# above guard the ENTRIES; the guard was written one level too deep, so the
# path the user actually types on the command line still reached the same
# unguarded `Fs::read_file` and produced the same bare trap -- the flag's most
# immediate invalid input was its least actionable one (Codex on #2956, P2).
# Both assert WHICH diagnostic appears: "not found" and "is a directory" are
# different mistakes, and a guard that collapses them sends the reader to the
# wrong fix.
got="$(cd "$app/sub" && vibe grep --file-list=./no_such_list.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
  && fail "vibe grep with a missing --file-list must fail, got exit 0: $got"
case "$got" in
  *"--file-list not found"*) ;;
  *) fail "a missing list FILE must say so, got: $got" ;;
esac
case "$got" in
  *"no_such_list.txt"*) ;;
  *) fail "a missing list FILE must name the file, got: $got" ;;
esac
case "$got" in
  *"wasm backtrace"*) fail "a missing list FILE still trapped: $got" ;;
  *) ;;
esac
# A DIRECTORY passes the existence check and fails inside the read as EISDIR.
mkdir -p "$app/sub/alistdir"
got="$(cd "$app/sub" && vibe grep --file-list=./alistdir --pattern 'Array::length($(x:exp))' . 2>&1)" \
  && fail "vibe grep with a directory as --file-list must fail, got exit 0: $got"
case "$got" in
  *"--file-list is a directory"*) ;;
  *) fail "a directory as the list FILE must say so, got: $got" ;;
esac
case "$got" in
  *"wasm backtrace"*|*EISDIR*) fail "a directory as the list FILE still reached the host read: $got" ;;
  *) ;;
esac
# CRLF. A list written by an editor that ends lines with \r\n must work: the
# splitter this one replaced trimmed every entry, so dropping the trim while
# consolidating rejected every valid path as missing -- a regression on the
# env-mode path too, not just the new one (Codex on #2956, P2). Splitting on
# `\n` alone is not reading lines.
printf 'sub/greppable.vibe\r\nsub/greppable2.vibe\r\n' > "$app/sub/crlflist.txt"
got="$(cd "$app/sub" && vibe grep --file-list=./crlflist.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
  || fail "vibe grep with a CRLF file-list failed: $got"
case "$got" in *"greppable.vibe:2:3"*) ;; *) fail "a CRLF file-list must sweep the same files a LF one does, got: $got" ;; esac
# THE DOCUMENTED ROUND TRIP, run as documented. `grep --help` says the output
# of --list-files is the input of --file-list; it was not, because --list-files
# leads with the format banner and the reader took it for a source path. The
# two shell drivers hid that by stripping line 1 themselves, so the contract
# held for the code that knew the trick and not for the one the help described
# (Codex on #2956, P2). No `sed` here on purpose: this is the user's spelling.
( cd "$app/sub" && vibe grep --list-files --pattern 'Array::length($(x:exp))' . > ./roundtrip.txt 2>&1 ) \
  || fail "vibe grep --list-files from a subdirectory failed: $(cat "$app/sub/roundtrip.txt")"
head -1 "$app/sub/roundtrip.txt" | grep -q '^vibe-grep-file-list-v1$' \
  || fail "--list-files no longer leads with the banner, so this round trip tests nothing: $(head -1 "$app/sub/roundtrip.txt")"
got="$(cd "$app/sub" && vibe grep --file-list=./roundtrip.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
  || fail "the documented --list-files | --file-list round trip failed: $got"
case "$got" in *"greppable.vibe:2:3"*) ;; *) fail "the round trip found no match, got: $got" ;; esac
case "$got" in *"vibe-grep-file-list-v1"*) fail "the banner reached the sweep as a path: $got" ;; *) ;; esac
# AN ESCAPED NEWLINE IN A LIST DECODES BACK TO THE REAL NAME. A POSIX
# filename may contain a newline, and the list format escapes it (`\n`) so one
# path stays one line -- the same answer #2723 gave for `vibe symbols` NAME
# fields, after the same defect.
#
# Driven first from a HAND-WRITTEN list, which proves the decoder on its own,
# and then from the walk itself (`--list-files`), which proves the name
# reaches the list intact. The walk half used to be impossible: `Fs::readdir`
# framed entry names as one "\n"-joined string at the host boundary, so the
# walk yielded `sub/nl/ird.vibe` with the `we` fragment dropped for not ending
# in `.vibe`. #2957 moved that framing to NUL (`fs_read_dir_nul`), the one byte
# a POSIX name cannot hold, so the walk now lists the real name.
nl_dir="$app/sub/nl"
nl_name="$nl_dir/we"$'\n'"ird.vibe"
mkdir -p "$nl_dir"
printf 'export fn nlfn(zs: Array[String]) -> Int {\n  Array::length(zs)\n}\n' > "$nl_name" 2>/dev/null || true
if [ -e "$nl_name" ] && [ "$(printf '%s' "$nl_name" | wc -l | tr -d ' ')" = "1" ]; then
  # Banner + the path with its newline ESCAPED: one record, one line.
  printf 'vibe-grep-file-list-v1\nsub/nl/we\\nird.vibe\n' > "$app/sub/esc_list.txt"
  [ "$(grep -c . "$app/sub/esc_list.txt")" = "2" ] \
    || fail "the escaped list is not 2 lines: $(cat -A "$app/sub/esc_list.txt")"
  got="$(cd "$app/sub" && vibe grep --file-list=./esc_list.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
    || fail "an escaped newline path was not decoded back to a real file: $got"
  case "$got" in *"ird.vibe:2:3"*) ;; *) fail "no match from the newline-named file: $got" ;; esac
  # The walk lists the newline-named file as ONE escaped path (#2957), and the
  # fragments the "\n" readdir framing produced are gone.
  got="$(cd "$app/sub" && vibe grep --list-files --pattern 'Array::length($(x:exp))' ./nl 2>&1)" \
    || fail "vibe grep --list-files over a newline-named file failed: $got"
  case "$got" in *'sub/nl/we\nird.vibe'*) ;; *) fail "the walk did not list the newline-named file as one escaped path: $got" ;; esac
  case "$got" in *'sub/nl/ird.vibe'*) fail "readdir split a newline-named file into fake entries: $got" ;; *) ;; esac
  # The control: the SAME list without the banner must NOT be decoded, because
  # a hand-written list is not in the encoded format and a literal backslash
  # belongs to the path.
  printf 'sub/nl/we\\nird.vibe\n' > "$app/sub/raw_list.txt"
  got="$(cd "$app/sub" && vibe grep --file-list=./raw_list.txt --pattern 'Array::length($(x:exp))' . 2>&1)" \
    && fail "a bannerless list was decoded anyway, so a literal backslash in a
hand-written path is being rewritten: $got"
  case "$got" in *"file-list entry not found"*) ;; *) fail "expected a named
missing entry for the undecoded literal path, got: $got" ;; esac
  pass "an escaped newline decodes back to the real name; the walk lists it as one path; a bannerless list is left alone"
else
  note "  skip: this filesystem rejected a newline in a filename"
fi
pass "vibe grep --file-list=/--resume-out resolve against the invoking directory; a missing entry AND a missing list file are named; CRLF lists work; --list-files round-trips into --file-list"

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

# --- 5b. VIBE_BUILD_DIR carries the compiler cache with it ------------------
# The compiler roots its cache at the literal `.vibe/build/cache/` under its
# cwd (the root), so an overridden build directory has to take the cache
# along, or `vibe clean` under the override removes the artifacts and leaves
# the cache growing at the root. Measured before the fix: the artifact moved
# and the cache did not.
bd="$WORK/bd"
got="$(cd "$app/sub" && VIBE_BUILD_DIR="$bd" vibe run deep.vibex 2>&1)" || fail "vibe run with VIBE_BUILD_DIR failed: $got"
[ "$got" = "42 from-sub" ] || fail "vibe run with VIBE_BUILD_DIR: expected '42 from-sub', got '$got'"
[ -s "$bd/run/deep.wasm" ] || fail "VIBE_BUILD_DIR: the artifact did not land at $bd/run/deep.wasm"
[ -d "$bd/cache" ] || fail "VIBE_BUILD_DIR: the compiler cache did not follow the build directory to $bd/cache/"
n_cache="$(find "$bd/cache" -maxdepth 1 -name 'vibe_*' | wc -l | tr -d ' ')"
[ "$n_cache" -gt 0 ] || fail "VIBE_BUILD_DIR: $bd/cache/ exists but holds no compiler cache files"
n_root="$( { find "$app/.vibe/build/cache" -maxdepth 1 -name 'vibe_*' 2>/dev/null || true; } | wc -l | tr -d ' ')"
[ "$n_root" = "0" ] || fail "VIBE_BUILD_DIR: $n_root cache file(s) still landed under <root>/.vibe/build/cache/"
iso="$WORK/iso"
mkdir -p "$iso"
( cd "$app/sub" && VIBE_BUILD_DIR="$bd" VIBE_BUILD_CACHE_DIR="$iso" vibe run deep.vibex >/dev/null 2>&1 ) || fail "vibe run with VIBE_BUILD_DIR and VIBE_BUILD_CACHE_DIR failed"
n_iso="$(find "$iso" -maxdepth 1 -name 'vibe_*' | wc -l | tr -d ' ')"
[ "$n_iso" -gt 0 ] || fail "an explicit VIBE_BUILD_CACHE_DIR must win over the derived one: nothing landed under $iso"
got="$(cd "$app/sub" && VIBE_BUILD_DIR="$bd" vibe clean)"
[ "$got" = "cleaned: $bd" ] || fail "vibe clean with VIBE_BUILD_DIR: unexpected report: $got"
[ ! -e "$bd" ] || fail "vibe clean with VIBE_BUILD_DIR left $bd"
pass "VIBE_BUILD_DIR moves the artifacts and the compiler cache; an explicit VIBE_BUILD_CACHE_DIR still wins; vibe clean removes the override"

# --- 6. nothing left in the OS temp dir -------------------------------------
leftover="$(find "$WORK/tmp" -mindepth 1 | wc -l | tr -d ' ')"
[ "$leftover" = "0" ] || fail "the launcher left $leftover entr(ies) under TMPDIR: $(ls "$WORK/tmp" | head -5 | tr '\n' ' ')"
pass "no scratch left under TMPDIR"

echo "[vibe-root] ok (compiler: $compiler)"
