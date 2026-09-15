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
unset VIBE_COMPONENT_LAZY_WORK VIBE_COMPONENT_LAZY_COMPILER

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/test_component_lazy_dispatch_gate.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_component_lazy_selftest.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
  if VIBE_COMPONENT_LAZY_WORK="$work" bash "$GATE" >"$work/log" 2>&1; then
    echo "component-lazy self-test [$label]: the gate PASSED on a mutated tree" >&2
    exit 1
  fi
  grep -q "$want" "$work/log" \
    || { cat "$work/log" >&2; echo "component-lazy self-test [$label]: failed, but not with '$want'" >&2; exit 1; }
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

echo "component-lazy self-test: ok ($case_no cases)"
