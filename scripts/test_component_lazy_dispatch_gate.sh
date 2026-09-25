#!/usr/bin/env bash
# Lazy Component Model command dispatch, end to end.
#
# What this proves, in one sentence: `vibe build --component` emits an
# artifact that `viberun --commands` dispatches, and dispatching one verb
# costs NOTHING for the other verbs in the manifest.
#
# It drives the PUBLIC `runtime/vibe` launcher, not the CLI wasm underneath
# it. The first version of this gate invoked the wasm directly and was green
# while `vibe build --component f.vibe` through the launcher silently produced
# a CORE module -- the flag fell through a catch-all that treated it as the
# source path (Codex review of #2861). A gate that skips the layer the user
# types into tests a proxy for the thing it names.
#
# The laziness assertion is the reason the gate exists, so it is made the way
# that cannot be faked: the manifest's other rows point at a file that is not
# a wasm binary and at a path that does not exist, and the run is still
# expected to be clean. A loader that read, validated, or even stat'd the
# other rows fails here. `chmod 000` was the obvious probe and is the wrong
# one -- this repository's containers run as root, where permissions are not
# enforced and the probe would pass while proving nothing.
#
# The probe is then shown to BITE: dispatching the poisoned verb must fail.
# Without that half, "the good verb worked" is equally consistent with a
# manifest the runner never really read.
#
# WHICH COMPILER: the subject is the CLI built from THIS CHECKOUT's sources
# (lib/@vibe/cli/dispatch.vibe's `--component` handling and the component
# emitters it calls). The compiler that builds that CLI is a tool, not the
# subject, so the committed seed is the right default -- it is fixed, and a
# change to it cannot flatter the result. VIBE_COMPONENT_LAZY_COMPILER
# overrides it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COMPILER="${VIBE_COMPONENT_LAZY_COMPILER:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
WORK="${VIBE_COMPONENT_LAZY_WORK:-$ROOT_DIR/_build/component_lazy}"
BUILD_ONLY=0
PRINT_SOURCES_HASH=0
for arg in "$@"; do
  case "$arg" in
    --fixtures) ;;
    --build-only) BUILD_ONLY=1 ;;
    # Print the fixture cache key and stop, before anything is built. The
    # self-test asks this of a COPY of lib/ (below), so proving that the key
    # covers the compiler sources no longer means editing a tracked file in
    # the live checkout (#2899).
    --print-sources-hash) PRINT_SOURCES_HASH=1 ;;
    *) echo "usage: $0 [--build-only | --print-sources-hash]   (VIBE_COMPONENT_LAZY_WORK picks the fixture dir)" >&2; exit 2 ;;
  esac
done
# The tree whose lib/ the cache key hashes. VIBE_COMPONENT_LAZY_SOURCES_ROOT
# exists for the self-test alone, which points it at a scratch copy so it can
# mutate a compiler source without touching the checkout; every real run
# hashes the tree the build reads.
SOURCES_ROOT="${VIBE_COMPONENT_LAZY_SOURCES_ROOT:-$ROOT_DIR}"

fail() { echo "[component-lazy] FAIL: $*" >&2; exit 1; }

# The PUBLIC entry point, pointed at this checkout's runner and adapter. Every
# build in this gate goes through it, so a flag the launcher drops cannot pass
# unnoticed. VIBE_HOME is redirected so a toolchain installed on the machine
# cannot answer instead of the one under test.
# VIBE_COMPONENT_LAZY_LAUNCHER exists for the self-test alone: the launcher is
# repository content, not a fixture, so `expect_fail`'s copy-and-mutate cannot
# reach it otherwise -- and the one mutation that matters most (restoring the
# catch-all that swallowed `--component`) is a launcher mutation.
LAUNCHER="${VIBE_COMPONENT_LAZY_LAUNCHER:-$ROOT_DIR/runtime/vibe}"
[ -f "$LAUNCHER" ] || fail "launcher not found: $LAUNCHER"

launcher() {
  env VIBE_RUNNER="$RUNNER" VIBE_CLI_WASM="$CLI_WASM" VIBE_LIB="$ROOT_DIR/lib" \
      VIBE_HOME="$WORK/home" VIBE_BUILD_DIR="$WORK/build" \
    bash "$LAUNCHER" "$@"
}

# VIBE_COMPONENT_LAZY_RUNNER, like the launcher override below, exists for the
# self-test alone: the runner is a compiled binary, so the one mutation that
# reaches its argument POLICY (an invocation that always vouches for
# precompiled images) has to arrive as a shim in front of it.
RUNNER="${VIBE_COMPONENT_LAZY_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
bash "$ROOT_DIR/scripts/ensure_viberun.sh" >/dev/null || fail "could not build runtime/viberun"
[ -x "$RUNNER" ] || fail "no runner at $RUNNER"
[ -f "$COMPILER" ] || fail "compiler wasm not found: $COMPILER"

SEED_RUN="bash $ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
CLI_WASM="$WORK/vibe-cli.wasm"
STAMP="$WORK/.sources_sha"

hash_stdin() {
  if sha256sum </dev/null >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif shasum -a 256 </dev/null >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else fail "sha256sum or shasum is required"; fi
}

# Rebuild the fixtures when anything they are a function of changed. Content,
# not mtime: a CI checkout writes every source with mtime = now, so a
# timestamp comparison rebuilds always and a "newer than" comparison against a
# restored cache never does (scripts/ensure_viberun.sh learned this the hard
# way).
sources_hash() {
  {
    printf '%s ' "seed"; hash_stdin < "$COMPILER"
    # The whole of lib/@vibe, not just cli/ and command/. The CLI this gate
    # builds IMPORTS the compiler, and the component emitter it calls is in
    # lib/@vibe/compiler -- so a key over cli/ alone leaves a changed emitter
    # reusing yesterday's artifacts and the gate green about code it never ran
    # (Codex review of #2861). Over-approximating costs a rebuild the gate
    # would mostly have paid anyway; under-approximating costs the guarantee.
    ( cd "$SOURCES_ROOT" && find lib -type f \( -name '*.vibe' -o -name '*.vibex' -o -name '*.vpkg' \) 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; hash_stdin < "$f"; done )
    printf '%s ' "launcher"; hash_stdin < "$LAUNCHER"
    printf '%s ' "runner"; hash_stdin < "$RUNNER"
    printf '%s ' "gate"; hash_stdin < "$ROOT_DIR/scripts/test_component_lazy_dispatch_gate.sh"
  } | hash_stdin
}

build_fixtures() {
  mkdir -p "$WORK/cmd"
  # The command modules. `hello` is pure (no host imports, so `vibe build
  # --component` takes the strict wrap); `cat` reaches the filesystem, so the
  # same command takes the vfs wrap and its four read operations become
  # component imports this runner serves. `unframed` deliberately answers
  # without the result frame.
  cat > "$WORK/cmd/hello.vibe" <<'VIBE'
import @vibe/command { command_args, command_ok }

export fn vibe_command(args: String) -> String {
  let argv = command_args(args)
  command_ok("hello from \{Array::get(argv, 0)}, \{Array::length(argv) - 1} arg(s)\n")
}
VIBE
  cat > "$WORK/cmd/cat.vibe" <<'VIBE'
import @vibe/command { command_args, command_failed, command_ok }

export fn vibe_command(args: String) -> String with Fs {
  let argv = command_args(args)
  if Array::length(argv) < 2 {
    command_failed(2, "usage: cat <file>\n")
  } else {
    let path = Array::get(argv, 1)
    if Fs::exists(path) {
      command_ok(Fs::read_file(path))
    } else {
      command_failed(1, "cat: no such file: \{path}\n")
    }
  }
}
VIBE
  cat > "$WORK/cmd/unframed.vibe" <<'VIBE'
export fn vibe_command(args: String) -> String {
  String::concat("no frame here: ", args)
}
VIBE
  # Answers as if it always got three arguments. Nothing in the gate needs it;
  # it exists so the self-test has a mutation that satisfies the fixed-argv
  # assertion below while breaking the `--help` passthrough one, which no
  # substitution of the other fixtures can do.
  cat > "$WORK/cmd/alwaysthree.vibe" <<'VIBE'
import @vibe/command { command_args, command_ok }

export fn vibe_command(args: String) -> String {
  let argv = command_args(args)
  command_ok("hello from \{Array::get(argv, 0)}, 3 arg(s)\n")
}
VIBE

  # Writes to the filesystem, which a command component CANNOT do: the vfs
  # wrap gives it the four read operations and traps everything else. The
  # permissive wrap vibec uses answers a write with a benign zero instead, and
  # under it this command printed its own success line and exited 0 having
  # written nothing (#2861, Codex review).
  cat > "$WORK/cmd/writer.vibe" <<'VIBE'
import @vibe/command { command_args, command_ok }

export fn vibe_command(args: String) -> String with Fs {
  let argv = command_args(args)
  Fs::write_file(Array::get(argv, 1), "written by a command component\n")
  command_ok("wrote \{Array::get(argv, 1)}\n")
}
VIBE

  # A PAIR that differs only in reachability. Both import the formatter; only
  # `reaches` calls it from `vibe_command`. The command lane prunes from that
  # root, so the two must come out very different sizes -- and comparing them
  # against each other, rather than against a fixed number, is what keeps the
  # assertion meaningful as the formatter grows.
  cat > "$WORK/cmd/reaches.vibe" <<'VIBE'
import @vibe/command { command_args, command_ok }
import @vibe/compiler/fmt { format_script }

export fn vibe_command(args: String) -> String with Fs {
  let argv = command_args(args)
  command_ok(format_script(Fs::read_file(Array::get(argv, 1))))
}
VIBE
  cat > "$WORK/cmd/avoids.vibe" <<'VIBE'
import @vibe/command { command_args, command_ok }
import @vibe/compiler/fmt { format_script }

// Imported, exported, and NOT reachable from vibe_command.
export fn unreached_helper(src: String) -> String {
  format_script(src)
}

export fn vibe_command(args: String) -> String {
  command_ok("\{Array::length(command_args(args))}\n")
}
VIBE

  # Not a command module at all: `vibe build --component` must say so, and say
  # what to write instead.
  cat > "$WORK/cmd/noentry.vibe" <<'VIBE'
export fn something_else(args: String) -> String {
  args
}
VIBE

  # The compiler adapter this checkout's sources produce. This is what the
  # launcher actually drives (positional args + a VIBE_* selector), so it is
  # the artifact the gate has to exercise -- not lib/@vibe/cli/main.vibex,
  # which the public launcher never reaches.
  rm -f "$CLI_WASM" "$CLI_WASM.diag"
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw $SEED_RUN --invoke cli_main "$COMPILER" \
    lib/@vibe/compiler/cli_adapter.vibe "$CLI_WASM" cli_main >/dev/null 2>&1 || true
  if [ ! -s "$CLI_WASM" ]; then
    [ -s "$CLI_WASM.diag" ] && cat "$CLI_WASM.diag" >&2
    fail "could not build the compiler adapter from lib/@vibe/compiler/cli_adapter.vibe"
  fi
  rm -f "$CLI_WASM.diag" "$CLI_WASM.funcmap" "$CLI_WASM.testmeta"

  for name in hello cat unframed alwaysthree writer reaches avoids; do
    rm -f "$WORK/cmd/$name.component.wasm"
    launcher build --component "$WORK/cmd/$name.vibe" \
        -o "$WORK/cmd/$name.component.wasm" >/dev/null 2>"$WORK/cmd/$name.err" \
      || { cat "$WORK/cmd/$name.err" >&2; fail "vibe build --component failed for $name"; }
    [ -s "$WORK/cmd/$name.component.wasm" ] || fail "vibe build --component wrote nothing for $name"
  done

  # ...and the refusal is recorded here, where the toolchain is already built,
  # so the assertion below costs no second compile.
  rm -f "$WORK/cmd/noentry.component.wasm"
  if launcher build --component "$WORK/cmd/noentry.vibe" \
      -o "$WORK/cmd/noentry.component.wasm" >"$WORK/cmd/noentry.out" 2>"$WORK/cmd/noentry.err"; then
    fail "vibe build --component accepted a module with no \`vibe_command\` export"
  fi
  cat "$WORK/cmd/noentry.out" >> "$WORK/cmd/noentry.err"

  # The flag-combination refusals, recorded the same way.
  : > "$WORK/cmd/refusals.txt"
  # A `.vibex` can never carry an export, so `--component` on one is refused
  # at argument parsing rather than deep in compilation.
  printf 'fn main allows Console {\n  println("42")\n}\n' > "$WORK/cmd/root.vibex"
  for combo in "--component --wit" "--component --minify" "--component --entry x"; do
    # shellcheck disable=SC2086
    launcher build $combo "$WORK/cmd/hello.vibe" >>"$WORK/cmd/refusals.txt" 2>&1 \
      && fail "vibe build $combo was accepted"
  done
  launcher build --definitely-not-a-flag "$WORK/cmd/hello.vibe" >>"$WORK/cmd/refusals.txt" 2>&1 \
    && fail "vibe build accepted an unknown option instead of naming it"
  launcher build --component "$WORK/cmd/root.vibex" >>"$WORK/cmd/refusals.txt" 2>&1 \
    && fail "vibe build --component accepted a .vibex"
  true

  # The two poison rows. Neither is ever read on a lazy dispatch.
  printf 'this is not a wasm binary\n' > "$WORK/cmd/poison.component.wasm"
  rm -f "$WORK/cmd/absent.component.wasm"
}

want="$(sources_hash)"
if [ "$PRINT_SOURCES_HASH" = 1 ]; then
  printf '%s\n' "$want"
  exit 0
fi
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$want" ]; then
  echo "[component-lazy] building fixtures ($want)"
  rm -rf "$WORK"
  build_fixtures
  printf '%s\n' "$want" > "$STAMP"
else
  echo "[component-lazy] fixtures up to date ($want)"
fi

[ "$BUILD_ONLY" = 1 ] && { echo "[component-lazy] built only"; exit 0; }

# ---------------------------------------------------------------- assertions

# 1. `vibe build --component` really emitted Component Model binaries, not
#    core modules wearing a `.component.wasm` name.
for name in hello cat unframed writer; do
  head_bytes="$(od -A n -t x1 -N 8 "$WORK/cmd/$name.component.wasm" | tr -d ' \n')"
  [ "$head_bytes" = "0061736d0d000100" ] \
    || fail "$name.component.wasm is not a component (header $head_bytes)"
done

# 2. The manifest. `hello` and `cat` are real; `poison` is not a wasm binary
#    and `absent` does not exist at all.
cat > "$WORK/commands.tsv" <<TSV
# built by scripts/test_component_lazy_dispatch_gate.sh
vibe-commands-v1
hello	cmd/hello.component.wasm
cat	cmd/cat.component.wasm
poison	cmd/poison.component.wasm
absent	cmd/absent.component.wasm
TSV

run_cmd() {
  "$RUNNER" --commands "$WORK/commands.tsv" "$@" >"$WORK/out" 2>"$WORK/err"
}

# 3. THE LAZINESS ASSERTION. Two of the four rows cannot be loaded; a
#    dispatch of `hello` must not notice.
if ! run_cmd hello a b c; then
  cat "$WORK/err" >&2
  # Two readings, and the stderr above tells them apart: either the loader
  # touched the unloadable rows (the property under test), or `hello` itself
  # is broken. Step 4 below is what rules out a manifest nobody read.
  fail "dispatching \`hello\` failed although only \`hello\` should have been loaded"
fi
grep -qx 'hello from hello, 3 arg(s)' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "unexpected \`hello\` output"; }

# 4. ...and the probe BITES. If `poison` loaded cleanly, step 3 proved
#    nothing about laziness.
if run_cmd poison; then
  fail "the poisoned row loaded cleanly, so the laziness probe proves nothing"
fi
grep -q 'not a wasm binary' "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "poisoned row failed without naming what it is"; }

if run_cmd absent; then
  fail "the absent row loaded cleanly, so the laziness probe proves nothing"
fi

# 5. The vfs wrap: a command that reaches the filesystem reads a real file
#    through this runner's host imports, and its exit code comes back.
printf 'world-from-file\n' > "$WORK/data.txt"
run_cmd cat "$WORK/data.txt" || { cat "$WORK/err" >&2; fail "\`cat\` on an existing file failed"; }
grep -qx 'world-from-file' "$WORK/out" || { cat "$WORK/out" >&2; fail "\`cat\` returned the wrong bytes"; }

# `status=$?` after `cmd && fail ...` reads the AND-list, not the command, so
# capture through `|| status=$?` instead -- the form that also keeps `set -e`
# from aborting on the failure this assertion is here to observe.
status=0
run_cmd cat "$WORK/definitely-not-here" || status=$?
[ "$status" = 1 ] || fail "\`cat\` on a missing file exited $status, expected the command's own 1"

status=0
run_cmd cat || status=$?
[ "$status" = 2 ] || fail "\`cat\` with no argument exited $status, expected the command's own 2"

# 6. A component that answers without the frame is REFUSED, not reported as a
#    success with its raw string as output. This is the whole reason the frame
#    is mandatory.
cat > "$WORK/unframed.tsv" <<TSV
vibe-commands-v1
unframed	cmd/unframed.component.wasm
TSV
if "$RUNNER" --commands "$WORK/unframed.tsv" unframed >"$WORK/out" 2>"$WORK/err"; then
  fail "an unframed result was accepted as a successful command"
fi
grep -q 'vibe-command-result-v1' "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "the unframed refusal does not name the frame it wanted"; }

# 7. An unknown verb names the ones the manifest does define.
if run_cmd nosuchverb; then
  fail "an unknown verb exited 0"
fi
grep -q 'unknown command `nosuchverb`' "$WORK/err" || { cat "$WORK/err" >&2; fail "unknown verb: wrong message"; }
grep -q 'absent, cat, hello, poison' "$WORK/err" || { cat "$WORK/err" >&2; fail "unknown verb: the known verbs are not listed"; }

# 8. AOT, and the trust boundary around it. Loading a precompiled image runs
#    native code no wasm sandbox contains, so a MANIFEST -- which is data --
#    must not be able to select one on its own. The invoker vouches, or the
#    row is refused.
"$RUNNER" --precompile-component "$WORK/cmd/hello.component.wasm" -o "$WORK/cmd/hello.cwasm" >/dev/null 2>&1 \
  || fail "--precompile-component failed"
[ -s "$WORK/cmd/hello.cwasm" ] || fail "--precompile-component wrote nothing"
cat > "$WORK/aot.tsv" <<TSV
vibe-commands-v1
hello	cmd/hello.cwasm
TSV
if "$RUNNER" --commands "$WORK/aot.tsv" hello a b c >"$WORK/out" 2>"$WORK/err"; then
  fail "a manifest selected a precompiled image with no --trust-precompiled"
fi
grep -q -- '--trust-precompiled' "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "the precompiled refusal does not name the flag that allows it"; }

"$RUNNER" --commands --trust-precompiled "$WORK/aot.tsv" hello a b c >"$WORK/out" 2>"$WORK/err" \
  || { cat "$WORK/err" >&2; fail "dispatch from a precompiled component failed with --trust-precompiled"; }
grep -qx 'hello from hello, 3 arg(s)' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "the precompiled component answered differently"; }

# An option after the verb belongs to the COMMAND, so it must not be read as
# the runner's own -- otherwise the trust flag could be smuggled past the
# invoker by whatever supplies the command's arguments.
if "$RUNNER" --commands "$WORK/aot.tsv" hello --trust-precompiled >"$WORK/out" 2>"$WORK/err"; then
  fail "--trust-precompiled after the verb was honoured by the runner"
fi

# An unrecognized runner option is refused rather than taken for the manifest.
if "$RUNNER" --commands --definitely-not-a-flag "$WORK/aot.tsv" hello >"$WORK/out" 2>"$WORK/err"; then
  fail "an unknown --commands option was accepted"
fi
grep -q -- 'unknown option' "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "an unknown --commands option was not named"; }

# 9. A manifest that lists a verb twice is refused: dispatch must not depend
#    on which row a scan happens to reach first.
cat > "$WORK/dup.tsv" <<TSV
vibe-commands-v1
hello	cmd/hello.component.wasm
hello	cmd/cat.component.wasm
TSV
if "$RUNNER" --commands "$WORK/dup.tsv" hello >"$WORK/out" 2>"$WORK/err"; then
  fail "a manifest with a duplicate verb was accepted"
fi
grep -q 'listed twice' "$WORK/err" || { cat "$WORK/err" >&2; fail "duplicate verb: wrong message"; }

# 10. A core module named in a manifest is told what to do about it.
cat > "$WORK/core.tsv" <<TSV
vibe-commands-v1
cli	vibe-cli.wasm
TSV
if "$RUNNER" --commands "$WORK/core.tsv" cli >"$WORK/out" 2>"$WORK/err"; then
  fail "a core module was accepted as a command component"
fi
grep -q 'vibe build --component' "$WORK/err" \
  || { cat "$WORK/err" >&2; fail "a core module's refusal does not name the build that fixes it"; }

# 11. The command lane PRUNES from `vibe_command`. Two modules that differ
#     only in whether they reach the formatter must not ship the same bytes.
#     Measured on this tree, the same pair built by each lane:
#
#       no-dce    reaches=84,084  avoids=83,154  ->  98%
#       dce-root  reaches=77,317  avoids=27,986  ->  36%
#
#     So the threshold below separates the lanes by a wide margin in both
#     directions: a lane that stopped pruning lands at ~98%, not near 60%.
#
#     Compared to EACH OTHER rather than to a fixed size, so the assertion
#     survives the formatter growing.
reaches_bytes="$(wc -c < "$WORK/cmd/reaches.component.wasm" | tr -d ' ')"
avoids_bytes="$(wc -c < "$WORK/cmd/avoids.component.wasm" | tr -d ' ')"
[ "$reaches_bytes" -gt 0 ] && [ "$avoids_bytes" -gt 0 ] \
  || fail "could not size the reachability pair"
# 60% of the reaching build: midway between the 36% this lane produces and
# the 98% the unpruned lane produced (both measured above).
if [ $((avoids_bytes * 100 / reaches_bytes)) -ge 60 ]; then
  fail "the command lane did not prune: a module that never reaches the formatter is ${avoids_bytes}B against ${reaches_bytes}B for one that does ($((avoids_bytes * 100 / reaches_bytes))% -- expected well under 60%)"
fi

# 12. A command that WRITES must not report success. The wrap has no write
#     capability, so the call traps -- loudly, rather than being answered with
#     a benign zero that leaves the caller believing the file exists.
cat > "$WORK/writer.tsv" <<TSV
vibe-commands-v1
write	cmd/writer.component.wasm
TSV
rm -f "$WORK/written.txt"
if "$RUNNER" --commands "$WORK/writer.tsv" write "$WORK/written.txt" >"$WORK/out" 2>"$WORK/err"; then
  fail "a command that writes reported success; the write was answered instead of trapping"
fi
[ -s "$WORK/out" ] && { cat "$WORK/out" >&2; fail "a trapped command still printed its success line"; }
[ -e "$WORK/written.txt" ] && fail "the write actually happened, so this assertion is testing the wrong thing"
true

# 13. A flag the COMMAND owns reaches the command. `--help` is the one that
#     matters: this runner has its own, scanned across the whole argv, and a
#     verb's `--help` must not be answered by the host.
run_cmd hello --help || { cat "$WORK/err" >&2; fail "\`hello --help\` did not reach the command"; }
grep -qx 'hello from hello, 1 arg(s)' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "\`--help\` was swallowed by the runner instead of reaching the command"; }

# 14. The flag-combination refusals reached the user, each naming its own
#     reason. Recorded while the fixtures were built.
grep -q -- '--component and --wit' "$WORK/cmd/refusals.txt" \
  || { cat "$WORK/cmd/refusals.txt" >&2; fail "--component --wit was not refused with its own reason"; }
grep -q -- '--component and --minify' "$WORK/cmd/refusals.txt" \
  || { cat "$WORK/cmd/refusals.txt" >&2; fail "--component --minify was not refused with its own reason"; }
grep -q -- '--entry is not allowed' "$WORK/cmd/refusals.txt" \
  || { cat "$WORK/cmd/refusals.txt" >&2; fail "--component --entry was not refused with its own reason"; }
# The catch-all that swallowed `--component` as a source path is gone: an
# unknown option is NAMED. Without this, a future flag can be discarded the
# same way and every other assertion here still passes.
grep -q -- 'unknown option: --definitely-not-a-flag' "$WORK/cmd/refusals.txt" \
  || { cat "$WORK/cmd/refusals.txt" >&2; fail "an unknown build option was swallowed instead of named"; }
# ...and the .vibex refusal names the module kind to write instead, rather than
# letting the loader complain about exports several layers down.
grep -q -- '--component needs a .vibe module' "$WORK/cmd/refusals.txt" \
  || { cat "$WORK/cmd/refusals.txt" >&2; fail "--component on a .vibex was not refused with its own reason"; }

# 15. A module without the command entry is refused at BUILD time, with the
#     signature to write. The refusal itself was recorded while the fixtures
#     were built.
grep -q 'export fn vibe_command(args: String) -> String' "$WORK/cmd/noentry.err" \
  || { cat "$WORK/cmd/noentry.err" >&2; fail "build --component on a module with no entry does not name the signature to write"; }
grep -q 'vibe-command-result-v1' "$WORK/cmd/noentry.err" \
  || { cat "$WORK/cmd/noentry.err" >&2; fail "build --component on a module with no entry does not name the result frame"; }

echo "[component-lazy] ok"
