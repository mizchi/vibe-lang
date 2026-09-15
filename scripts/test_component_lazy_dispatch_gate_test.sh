#!/usr/bin/env bash
# Red test for scripts/test_component_lazy_dispatch_gate.sh (#2248 rule).
#
# A gate that has never been seen to fail is a filename. Each case below
# mutates a REAL fixture the gate built and asserts the gate reports FAIL with
# the message that names the property, so a future edit that quietly drops an
# assertion is caught here rather than by a reviewer.
#
# The fixtures are built once, by the gate itself, and every case then runs
# against a COPY -- so the expensive step is paid once and no case can leave
# the next one a mutated tree.
set -euo pipefail

# The gate reads two variables from the environment, and .claude/hooks can
# export project-wide values. Inheriting one would silently point a case at
# the wrong tree or the wrong compiler, which is how five self-tests in #2252
# came to be "broken": unset first, set explicitly per case.
unset VIBE_COMPONENT_LAZY_WORK VIBE_COMPONENT_LAZY_COMPILER VIBE_COMPONENT_LAZY_LAUNCHER \
      VIBE_COMPONENT_LAZY_RUNNER

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/test_component_lazy_dispatch_gate.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_component_lazy_selftest.XXXXXX")"

# Case 11 edits a TRACKED compiler source in the real checkout, so its
# restoration belongs in the trap, not on the happy path: an interrupt, a kill,
# or an early exit anywhere in the expensive nested gate would otherwise leave
# the developer's tree modified (Codex review of #2861). The trap runs on the
# normal exit too, so the restore is unconditional rather than duplicated.
MUTATED_SOURCE=""
MUTATED_BACKUP=""
cleanup() {
  if [ -n "$MUTATED_SOURCE" ] && [ -f "$MUTATED_BACKUP" ]; then
    cp "$MUTATED_BACKUP" "$MUTATED_SOURCE"
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

MASTER="$TMP_ROOT/master"
VIBE_COMPONENT_LAZY_WORK="$MASTER" bash "$GATE" --build-only >/dev/null \
  || { echo "component-lazy self-test: could not build the fixtures" >&2; exit 1; }

# Green first. A red test whose baseline is already red proves nothing about
# the mutation -- the failure would be the tree, not the edit.
VIBE_COMPONENT_LAZY_WORK="$MASTER" bash "$GATE" >"$TMP_ROOT/green" 2>&1 \
  || { cat "$TMP_ROOT/green" >&2; echo "component-lazy self-test: the unmutated tree does not pass" >&2; exit 1; }

case_no=0
# Run the gate over a fresh copy of the fixtures, with `mutate` applied to it,
# and require a failure whose message contains `$want`.
expect_fail() {
  local label="$1" want="$2" mutate="$3"
  case_no=$((case_no + 1))
  local work="$TMP_ROOT/case$case_no"
  rm -rf "$work"
  cp -R "$MASTER" "$work"
  ( cd "$work" && eval "$mutate" ) \
    || { echo "component-lazy self-test [$label]: the mutation itself failed" >&2; exit 1; }
  # The stamp still matches the sources, so the gate reuses what is there
  # rather than rebuilding over the mutation.
  # The log lives OUTSIDE $work: the gate wipes its work directory whenever
  # the cache key misses, which would take the log with it.
  local log="$TMP_ROOT/case$case_no.log"
  if VIBE_COMPONENT_LAZY_WORK="$work" bash "$GATE" >"$log" 2>&1; then
    echo "component-lazy self-test [$label]: the gate PASSED on a mutated tree" >&2
    exit 1
  fi
  grep -q "$want" "$log" \
    || { cat "$log" >&2; echo "component-lazy self-test [$label]: failed, but not with '$want'" >&2; exit 1; }
  echo "component-lazy self-test [$label]: red as expected"
}

# 1. The dispatch assertion is real. The mutation has to stay a VALID
#    component -- a corrupted one is caught by the header check two steps
#    earlier, which would make this case prove that check instead. `unframed`
#    is a real component whose answer the runner refuses, so the dispatch
#    fails exactly where step 3 looks.
expect_fail "dispatched component replaced by one that answers unframed" \
  "dispatching .hello. failed" \
  "cp cmd/unframed.component.wasm cmd/hello.component.wasm"

# 2. The probe must BITE. If the poisoned row is quietly replaced by a valid
#    component, step 3's "hello worked" no longer proves laziness -- and the
#    gate has to notice that its own probe went blunt. `hello` is the
#    substitute because it exits 0: a command that merely exits non-zero would
#    trip a different assertion and this case would prove that one instead.
expect_fail "poison row made loadable" \
  "the poisoned row loaded cleanly" \
  "cp cmd/hello.component.wasm cmd/poison.component.wasm"

# 3. ...including the row that is supposed to be absent.
expect_fail "absent row made loadable" \
  "the absent row loaded cleanly" \
  "cp cmd/hello.component.wasm cmd/absent.component.wasm"

# 4. The mandatory result frame is really checked: give the deliberately
#    unframed component a framed answer and the gate must object that an
#    unframed result was accepted.
expect_fail "unframed component made framed" \
  "an unframed result was accepted" \
  "cp cmd/hello.component.wasm cmd/unframed.component.wasm"

# 5. The vfs half is really exercised: swap the filesystem-reading command for
#    the pure one and the `cat` assertions must stop passing.
expect_fail "vfs command swapped for a pure one" \
  "returned the wrong bytes" \
  "cp cmd/hello.component.wasm cmd/cat.component.wasm"

# 6. The header check is real: a core module wearing a .component.wasm name
#    must not be accepted as a component.
expect_fail "component replaced by a core module" \
  "is not a component" \
  "cp vibe-cli.wasm cmd/hello.component.wasm"

# 7. The build-time refusal is really checked: a recorded refusal that no
#    longer names the signature must stop the gate.
expect_fail "build refusal stops naming the signature" \
  "does not name the signature to write" \
  "printf 'build --component: nope\n' > cmd/noentry.err"

# 8. The `--help` passthrough assertion is real: a component that answers
#    something else must turn the gate red there.
# `alwaysthree` exists for exactly this: it satisfies the fixed-argv
# assertion (`hello a b c` -> "3 arg(s)") and answers `--help` with the same
# string, so the only assertion it breaks is the passthrough one. Substituting
# any other fixture trips an earlier assertion and would prove that one instead.
expect_fail "help passthrough answer changed" \
  "was swallowed by the runner" \
  "cp cmd/alwaysthree.component.wasm cmd/hello.component.wasm"

# 9. THE ONE THIS GATE EXISTS FOR. Take `--component` back out of the public
#    launcher -- the state the first version of this gate was green about,
#    because it invoked the CLI wasm directly instead of the launcher the user
#    types into. The gate must not survive that.
#
#    Launcher mutations, not fixture ones, so they go through
#    VIBE_COMPONENT_LAZY_LAUNCHER rather than expect_fail's copied tree.
expect_launcher_fail() {
  local label="$1" want="$2" sed_script="$3" gone="$4"
  case_no=$((case_no + 1))
  local work="$TMP_ROOT/case$case_no" mutant="$TMP_ROOT/launcher$case_no" log="$TMP_ROOT/case$case_no.log"
  rm -rf "$work"
  cp -R "$MASTER" "$work"
  sed "$sed_script" "$ROOT/runtime/vibe" > "$mutant"
  # The mutation must have LANDED. An edit that matches nothing passes while
  # proving nothing -- the failure mode #2248 records twice.
  if grep -qF -- "$gone" "$mutant"; then
    echo "component-lazy self-test [$label]: the mutation did not apply" >&2
    exit 1
  fi
  # The cache key covers the launcher, so a mutated one forces a rebuild --
  # which is what makes the mutant, not a cached artifact, give the answer.
  if VIBE_COMPONENT_LAZY_WORK="$work" VIBE_COMPONENT_LAZY_LAUNCHER="$mutant" \
     bash "$GATE" >"$log" 2>&1; then
    echo "component-lazy self-test [$label]: the gate PASSED on a mutated launcher" >&2
    exit 1
  fi
  grep -q "$want" "$log" \
    || { cat "$log" >&2; echo "component-lazy self-test [$label]: failed, but not with '$want'" >&2; exit 1; }
  echo "component-lazy self-test [$label]: red as expected"
}

expect_launcher_fail "launcher forgets --component" \
  "vibe build --component failed" \
  's/        --component) component=1; shift ;;//' \
  '--component) component=1'

# 10. ...and the structural half: the catch-all that swallowed `--component`
#     as a source path is what let it through silently in the first place. With
#     the refusal removed, any FUTURE flag can be dropped the same way, and the
#     gate has to notice.
expect_launcher_fail "launcher swallows an unknown flag again" \
  "an unknown build option was swallowed" \
  's/        -\*) die "\$cmd: unknown option: \$1" ;;//' \
  'unknown option: $1'

# 11. The `.vibex` refusal is real: take it out of the launcher and the gate
#     must notice, rather than letting every such build fail several layers
#     down with a message about exports.
expect_launcher_fail "launcher accepts a .vibex for --component" \
  "was not refused with its own reason" \
  's/        \*.vibex) die "--component needs a .vibe module.*$//' \
  '--component needs a .vibe module'

# 12. A writing command must not be able to report success. Swap it for one
#     that exits 0 and writes nothing -- exactly what the permissive vfs wrap
#     produced before the trapping wrap replaced it -- and the gate must say so.
expect_fail "writing command reports success" \
  "reported success; the write was answered instead of trapping" \
  "cp cmd/hello.component.wasm cmd/writer.component.wasm"

# 13. The precompiled-trust boundary is real.
#
#     The mutation has to reach the runner's ARGUMENT POLICY, not a fixture.
#     An earlier attempt renamed precompiled bytes onto a component row, which
#     tripped the header assertion several steps before the trust one -- so it
#     stayed red whether or not the refusal existed, certifying a boundary it
#     never reached (Codex review of a5a4156). The runner is a compiled binary,
#     so the mutation arrives as a shim that always vouches: every `--commands`
#     invocation gets `--trust-precompiled` whether the gate asked for it or
#     not. The gate's "no flag must be refused" assertion then has to fire, and
#     every earlier assertion still runs unchanged.
case_no=$((case_no + 1))
trust_work="$TMP_ROOT/case$case_no"
trust_log="$TMP_ROOT/case$case_no.log"
trust_shim="$TMP_ROOT/viberun-always-trusts"
rm -rf "$trust_work"
cp -R "$MASTER" "$trust_work"
cat > "$trust_shim" <<SHIM
#!/usr/bin/env bash
# Inject --trust-precompiled right after --commands; pass everything else
# through untouched so only the policy under test changes.
if [ "\${1:-}" = "--commands" ]; then
  shift
  exec "$ROOT/runtime/viberun/target/release/viberun" --commands --trust-precompiled "\$@"
fi
exec "$ROOT/runtime/viberun/target/release/viberun" "\$@"
SHIM
chmod +x "$trust_shim"
# The mutation must have LANDED: the shim really does vouch where the gate did
# not ask it to.
if ! grep -q -- '--trust-precompiled' "$trust_shim"; then
  echo "component-lazy self-test [precompiled trust boundary]: the mutation did not apply" >&2
  exit 1
fi
if VIBE_COMPONENT_LAZY_WORK="$trust_work" VIBE_COMPONENT_LAZY_RUNNER="$trust_shim" \
   bash "$GATE" >"$trust_log" 2>&1; then
  echo "component-lazy self-test [precompiled trust boundary]: the gate PASSED while every dispatch vouched for precompiled images" >&2
  exit 1
fi
# ...and red at the TRUST assertion, not at some earlier one it happened to
# disturb. That distinction is the whole point of this case.
grep -q 'selected a precompiled image with no --trust-precompiled' "$trust_log" \
  || { cat "$trust_log" >&2; echo "component-lazy self-test [precompiled trust boundary]: red, but not at the trust assertion" >&2; exit 1; }
echo "component-lazy self-test [precompiled trust boundary]: red as expected"

# 14. The compiler-source half of the cache key (Codex P2): a change under
#     lib/@vibe/compiler must force a rebuild, or a changed emitter is reused
#     from yesterday's artifacts and the gate is green about code it never ran.
case_no=$((case_no + 1))
stamp_before="$(cat "$MASTER/.sources_sha")"
touch_work="$TMP_ROOT/case$case_no"
rm -rf "$touch_work"
cp -R "$MASTER" "$touch_work"
MUTATED_SOURCE="$ROOT/lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe"
MUTATED_BACKUP="$TMP_ROOT/component_codegen.orig"
cp "$MUTATED_SOURCE" "$MUTATED_BACKUP"
printf '\n// self-test: proves the cache key covers the compiler sources.\n' >> "$MUTATED_SOURCE"
stamp_after="$(VIBE_COMPONENT_LAZY_WORK="$touch_work" bash "$GATE" --build-only >/dev/null 2>&1; cat "$touch_work/.sources_sha")"
cp "$MUTATED_BACKUP" "$MUTATED_SOURCE"
MUTATED_SOURCE=""
if [ "$stamp_before" = "$stamp_after" ]; then
  echo "component-lazy self-test [compiler source in the cache key]: a change under lib/@vibe/compiler left the key unchanged, so the fixtures would be reused" >&2
  exit 1
fi
echo "component-lazy self-test [compiler source in the cache key]: red as expected"

echo "component-lazy self-test: ok ($case_no cases)"
