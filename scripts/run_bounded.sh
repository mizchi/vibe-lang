#!/usr/bin/env bash
# run_bounded.sh -- one portable spelling of `timeout SECS CMD...` (#2958).
#
# GNU `timeout` is coreutils. A stock macOS has no such binary (Homebrew's
# coreutils installs it as `gtimeout`), so a bare `timeout 60 cmd` there is
# `command not found` -- exit 127 -- which each caller then read as whatever
# 127 meant in its own logic: a compile crash, a failed gate, a finding. 96
# call sites across scripts/ and tests/ called it bare.
#
# Two ways to use it:
#
#   . "$ROOT_DIR/scripts/run_bounded.sh"      # sourced: defines run_bounded
#   run_bounded 60 "$RUNNER" "$COMPONENT"
#
#   bash scripts/run_bounded.sh 60 cmd args   # executed: for callers that
#                                             # hand a command STRING to a
#                                             # shell (scripts/vibe_md.vibex)
#
# Contract, identical to timeout(1) for everything a caller reads:
#   - the command's own exit status when it finishes within SECS;
#   - 124 when the bound was reached (the command is sent SIGTERM, then
#     SIGKILL two seconds later if it is still alive);
#   - 125 when the bound could not be enforced (see the watchdog below);
#   - SECS <= 0 runs the command with no bound, which is what the three
#     `run_with_timeout` copies this replaced already meant by 0.
#
# The command is ALWAYS bounded, whichever mechanism is present:
# `timeout`, else `gtimeout`, else the shell watchdog below. Running without a
# limit was the other option #2958 weighed, and it is right for a test runner
# but wrong for an oracle -- several callers here READ 124 (the fuzz oracle's
# HANG classes, vibe_md's "timed out after" line, the #2362 spin probe in the
# early gate), and there an unbounded run either deletes a result class or
# wedges the gate instead of reporting it. One mechanism that is correct for
# both is cheaper than a per-site decision that can be made wrong later.
#
# The watchdog is tests/fuzz/lib_oracle.sh's `watchdog_run` (#2955), whose
# contract rungs are pinned by tests/fuzz/stale_findings_test.sh; the two
# properties that are cheap to get wrong are kept here and pinned again by
# scripts/run_bounded_test.sh:
#   - killed-vs-died is decided by a MARKER, never by the exit status (a child
#     killed by SIGTERM reports 143 either way, so mapping 143 to 124 relabels
#     a program the OOM killer took as a hang);
#   - the signal goes to the PROCESS GROUP (job control on around the launch),
#     as timeout(1) does -- signalling only the direct child answers 124 while
#     a grandchild keeps running, and "a wrapper that spawns the real workload"
#     is the shape of nearly every call site here.
#
# VIBE_RUN_BOUNDED_IMPL (timeout | gtimeout | watchdog) forces one mechanism.
# It exists for scripts/run_bounded_test.sh alone, which has to exercise the
# watchdog on a machine that has GNU timeout.

run_bounded() { # <seconds> <cmd...>
  if [ "$#" -lt 2 ]; then
    echo "run_bounded: usage: run_bounded <seconds> <cmd...>" >&2
    return 125
  fi
  local secs="$1"
  shift
  case "$secs" in
    '' | *[!0-9]*)
      echo "run_bounded: the bound must be a whole number of seconds, got '$secs'" >&2
      return 125
      ;;
  esac
  if [ "$secs" -le 0 ]; then
    "$@"
    return $?
  fi
  local impl="${VIBE_RUN_BOUNDED_IMPL:-}"
  if [ -z "$impl" ]; then
    if command -v timeout >/dev/null 2>&1; then
      impl="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
      impl="gtimeout"
    else
      impl="watchdog"
    fi
  fi
  case "$impl" in
    "timeout" | "gtimeout")
      # Through a variable, so the tool name never sits in command position
      # where scripts/check_gate_portability.sh would read it as a bare call.
      # `-k 2`: timeout(1) only sends TERM by default, so a command that
      # ignores TERM would run on past the bound; escalate to KILL two seconds
      # later, as the watchdog does (#3099 review).
      #
      # After that escalation timeout(1) exits 137, not 124, which reads as a
      # crash to callers that classify 124 as a hang (tests/fuzz). A 137 past
      # the bound is the escalation; one before it is a real SIGKILL (the OOM
      # killer), and stays 137.
      local bin="$impl" start rc=0
      start="$(date +%s)"
      "$bin" -k 2 "$secs" "$@" || rc=$?
      # Whole seconds: a kill before the bound reads at most `secs` elapsed
      # (it can round UP to it), so only a 137 strictly past it -- where the
      # bound's TERM was already sent -- is the escalation (#3099 review).
      if [ "$rc" -eq 137 ] && [ $(($(date +%s) - start)) -gt "$secs" ]; then
        rc=124
      fi
      return "$rc"
      ;;
    "watchdog")
      run_bounded_watchdog "$secs" "$@"
      return $?
      ;;
    *)
      echo "run_bounded: VIBE_RUN_BOUNDED_IMPL must be timeout, gtimeout, or watchdog, got '$impl'" >&2
      return 125
      ;;
  esac
}

# A timeout(1)-compatible watchdog in shell, used only when neither binary
# exists. Every status below is captured with `&& rc=0 || rc=$?` rather than a
# bare `wait` followed by `$?`: callers run under `set -e`, and a bare `wait`
# on a failing child would end the CALLER right there, before the watcher is
# cancelled.
run_bounded_watchdog() { # <seconds> <cmd...>
  local secs="$1"
  shift
  # The marker is created HERE and removed by the watcher when the bound
  # fires, so its absence after the wait means "we killed it". Creating is the
  # step that can fail, and a failure here can be said out loud; guessing
  # afterwards is what the marker exists to avoid.
  local marker
  marker="$(mktemp "${TMPDIR:-/tmp}/vibe_run_bounded.XXXXXXXX" 2>/dev/null || true)"
  if [ -z "$marker" ] || [ ! -f "$marker" ]; then
    echo "run_bounded: no 'timeout' or 'gtimeout', and the fallback could not create its marker in ${TMPDIR:-/tmp}" >&2
    echo "run_bounded: set TMPDIR to a writable directory, or install GNU coreutils (macOS: 'brew install coreutils')" >&2
    return 125
  fi
  # Job control around the launch makes the child a process-group leader, so
  # `kill -TERM -PID` reaches the whole tree it spawned.
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    rm -f "$marker" 2>/dev/null
    kill -TERM "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
    sleep 2
    kill -KILL "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watch_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null && rc=0 || rc=$?
  if [ -e "$marker" ]; then
    # Finished on its own: cancel the watcher.
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    rm -f "$marker" 2>/dev/null || true
    return "$rc"
  fi
  # The bound fired. Let the watcher finish its TERM -> KILL escalation: a
  # descendant that ignores SIGTERM outlives the leader, and cancelling the
  # watcher here would leave nothing to send the SIGKILL.
  wait "$watch_pid" 2>/dev/null || true
  return 124
}

# Exported, because several callers (unit_test_runner.sh, vibe_test.sh,
# parallel_warm_pool.sh, doctest_extract_run.sh) call it from a worker that
# `xargs -P ... bash -c` starts: a function that is only defined, not
# exported, is `command not found` there -- exit 127 again, the very failure
# this file exists to remove.
export -f run_bounded run_bounded_watchdog

# Executed rather than sourced: run the command given on the command line.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_bounded "$@"
  exit $?
fi
