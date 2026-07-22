#!/usr/bin/env bash
# eval/lang-bench/acceptance_test.sh — language-agnostic mini-vcs driver.
# See SPEC.md for the full behavior spec and the fixed scenario this checks.
#
#   bash acceptance_test.sh "<run-command>"
#
# <run-command> is a shell command PREFIX that runs the tool; this script
# appends subcommand args and executes it in a fresh temp cwd. Examples:
#   bash acceptance_test.sh "/path/to/minivcs"                    # native binary
#   bash acceptance_test.sh "node /path/to/dist/minivcs.js"       # typescript
#   bash acceptance_test.sh "bash /path/to/run_vibe_minivcs.sh"   # vibe (wraps
#     the wasm invocation — see langs/vibe/README.md for why a wrapper is
#     needed: the compiled tool takes argv via the host runner's own
#     argv-forwarding convention, not a plain executable)
set -uo pipefail

RUN="${1:?usage: acceptance_test.sh \"<run-command>\"}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0
fail=0

check() {
  # check <label> <expected_exit> <expected_stdout_or_-> -- <cmd...>
  local label="$1" want_exit="$2" want_stdout="$3"
  shift 3
  local out rc
  out="$("$@" 2>/tmp/acceptance_stderr.$$)"
  rc=$?
  local ok=1
  [ "$rc" -eq "$want_exit" ] || ok=0
  if [ "$want_stdout" != "-" ] && [ "$out" != "$want_stdout" ]; then
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (exit=$rc want=$want_exit, stdout=[$out] want=[$want_stdout])"
    fail=$((fail + 1))
  fi
  rm -f "/tmp/acceptance_stderr.$$"
}

# 1. status before init: must not crash (bash's $? after `set -uo pipefail`
#    with a failing command in `out=$(...)` is captured, not fatal, since we
#    are not in `-e` mode).
$RUN status >/dev/null 2>&1
echo "PASS: status-before-init did not crash (any exit code ok)"
pass=$((pass + 1))

# 2. init
check "init" 0 "Initialized empty repository" $RUN init

# 3. init again
check "init-again" 1 "" $RUN init  # stdout empty; message goes to stderr per spec

# 4. seed working files
echo -n "hello" >a.txt
echo -n "world" >b.txt

# 5. status: nothing staged, both untracked
check "status-1" 0 "staged: (none)
untracked: a.txt,b.txt" $RUN status

# 6. add a.txt
check "add-a" 0 "Added a.txt" $RUN add a.txt

# 7. status: a staged, b untracked
check "status-2" 0 "staged: a.txt
untracked: b.txt" $RUN status

# 8. commit first
check "commit-1" 0 "Committed 1: first" $RUN commit -m first

# 9. status: stage cleared
check "status-3" 0 "staged: (none)
untracked: b.txt" $RUN status

# 10. add b.txt
check "add-b" 0 "Added b.txt" $RUN add b.txt

# 11. commit second
check "commit-2" 0 "Committed 2: second" $RUN commit -m second

# 12. log: newest first
check "log" 0 "2 second
1 first" $RUN log

# 13. commit with nothing staged
check "commit-empty" 1 "" $RUN commit -m empty

echo
echo "== acceptance: $pass pass / $fail fail =="
[ "$fail" -eq 0 ]
