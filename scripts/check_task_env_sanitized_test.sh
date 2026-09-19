#!/usr/bin/env bash
# Red test for check_task_env_sanitized.sh (#2248: a gate means nothing until
# it is known to be able to fail).
#
# Each mutation is checked for having LANDED before its verdict is believed --
# an edit that matches nothing passes while proving nothing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252 -- a self-test that picks up the
# session's environment silently no-ops the cases it was written for).
unset VIBE_TASK_ENV_ROOT
unset VIBE_TASK_ENV_PKF

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_taskenv_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[task-env-test] FAIL: $*" >&2; exit 1; }

# RED 4 asks the ambient pkf whether THIS environment leaks at all;
# the gate under test resolves its pkf the same way.
PKF_FOR_PROBE="${VIBE_TASK_ENV_PKF:-pkf}"

# GREEN control. Without it a gate that fails for an unrelated reason (no pkf,
# a broken Taskfile) would make every red case below "pass".
if ! bash scripts/check_task_env_sanitized.sh >"$WORK/out" 2>&1; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated tree; the red cases below would prove nothing"
fi

# The mutations replace `pkf` with a stub, because the real defect is a
# property of the ENVIRONMENT a task inherits and this self-test must not
# depend on being able to reintroduce a nix wrapper. The stub stands in for
# the canary task's output, which is the gate's entire input.
mkstub() { # mkstub <file> <lines...>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  { echo '#!/usr/bin/env bash'; for l in "$@"; do echo "$l"; done; } > "$f"
  chmod +x "$f"
}

# RED 1: the canary binary did not run. This is the actual failure mode --
# `sort` dies on the glibc version mismatch and writes nothing.
mkstub "$WORK/r1/pkf" \
  "echo 'task-env: LD_LIBRARY_PATH='" \
  "echo 'task-env: sort FAILED'"
grep -q 'sort FAILED' "$WORK/r1/pkf" || fail "RED 1 stub did not land"
if VIBE_TASK_ENV_PKF="$WORK/r1/pkf" bash scripts/check_task_env_sanitized.sh >"$WORK/out" 2>&1; then
  fail "RED 1: the gate passed while the canary binary did not run"
fi
grep -qF 'a system binary does not run inside a pkf task' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 2: the binary ran, but the variable still carries a nix store path. A
# gate that stopped at RED 1 would pass this, and the NEXT system binary --
# the one nobody canaried -- is the one that breaks.
mkstub "$WORK/r2/pkf" \
  "echo 'task-env: LD_LIBRARY_PATH=/nix/store/wc7dmdfbabw94764bw0wyzlsm1jys9da-openssl-3.6.3/lib'" \
  "echo 'task-env: sort ok'"
grep -q '/nix/store/' "$WORK/r2/pkf" || fail "RED 2 stub did not land"
if VIBE_TASK_ENV_PKF="$WORK/r2/pkf" bash scripts/check_task_env_sanitized.sh >"$WORK/out" 2>&1; then
  fail "RED 2: the gate passed a task inheriting a nix store path (it only checks the canary)"
fi
grep -qF 'inherits a nix store path' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

# RED 3: silence. A canary task that vanished, or a pkf that died before
# running it, must not read as clean -- "unchecked" and "clean" are
# indistinguishable from an exit code otherwise (#2248).
mkstub "$WORK/r3/pkf" "exit 1"
if VIBE_TASK_ENV_PKF="$WORK/r3/pkf" bash scripts/check_task_env_sanitized.sh >"$WORK/out" 2>&1; then
  fail "RED 3: the gate passed on no output at all"
fi
grep -qF 'a system binary does not run inside a pkf task' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

# RED 4: the fix itself, removed. This is the one that binds the gate to the
# thing it guards rather than to a stub -- the real Taskfile, the real pkf,
# with only the `defaults.env` row taken out.
#
# It carries a PRECONDITION the other three do not: the ambient `pkf` must
# actually leak. The defect is a property of one nix WRAPPER, and an
# environment whose pkf was installed another way has nothing to leak, so
# removing the row changes nothing and the gate correctly still passes.
# Asserting a red verdict there fails for a reason unrelated to the gate --
# the #2252 shape that gets a self-test exempted rather than fixed. This file
# had exactly that bug, and CI found it: `pkf: command not found` in a lane
# that does not install pkfire.
#
# So the precondition is MEASURED and the outcome reported either way. A run
# that could not exercise this case says so in its own line rather than
# counting it as passed -- silence is "unchecked", not "clean" (#2248).
red4="not-applicable"
cp Taskfile.pkl "$WORK/Taskfile.pkl.orig"
python3 - <<'PYX'
import re, sys
p = 'Taskfile.pkl'
s = open(p).read()
out = re.sub(r'\ndefaults \{\n  env \{\n    \["LD_LIBRARY_PATH"\] = ""\n  \}\n\}\n', '\n', s, count=1)
if out == s:
    sys.stderr.write('RED 4 mutation matched nothing\n'); sys.exit(2)
open(p, 'w').write(out)
PYX
if bash scripts/check_task_env_sanitized.sh >"$WORK/out" 2>&1; then
  # The row is gone and the gate still passes. Either the gate is not watching
  # the fix, or this environment has no leak for the row to clear. Ask the
  # ambient pkf directly, which is the only thing that can tell them apart.
  probe="$("$PKF_FOR_PROBE" run check-task-env 2>&1 || true)"
  leaked="$(printf '%s\n' "$probe" | sed -n 's/^task-env: LD_LIBRARY_PATH=//p')"
  cp "$WORK/Taskfile.pkl.orig" Taskfile.pkl
  case "$leaked" in
    *"/nix/store/"*)
      fail "RED 4: the row is REMOVED, this environment leaks ($leaked), and the gate still passed -- it is not watching the fix"
      ;;
    *)
      red4="n/a (this pkf does not leak; the row has nothing to clear here)"
      ;;
  esac
else
  cp "$WORK/Taskfile.pkl.orig" Taskfile.pkl
  if ! grep -qE 'does not run inside a pkf task|inherits a nix store path' "$WORK/out"; then
    cat "$WORK/out" >&2; fail "RED 4 failed for the wrong reason"
  fi
  red4="red"
fi

# And the tree is back the way it started.
bash scripts/check_task_env_sanitized.sh >/dev/null 2>&1 \
  || fail "the gate does not pass after restoring the Taskfile; the self-test left the tree dirty"

echo "[task-env-test] ok (3 red cases verified to land; RED 4: $red4)"
