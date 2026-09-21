#!/usr/bin/env bash
# Shared compile/run/classify helpers for the fuzz harness.
#
# Both tests/fuzz/run_fuzz.sh (the seed-sweeping differential fuzzer) and
# tests/fuzz/classify.sh (a single-candidate CLI used by tests/fuzz/reduce.py) source
# this file so the "what counts as a finding" logic lives in exactly one
# place. Factored out of run_fuzz.sh in #765 so the delta-debugging
# reducer can replay the identical oracle per candidate instead of
# re-implementing it.
#
# Callers must set ROOT and CLI before sourcing this file. RUNNER/
# CTIMEOUT/RTIMEOUT have defaults but may be overridden first.
: "${ROOT:?lib_oracle.sh: ROOT must be set before sourcing}"
: "${CLI:?lib_oracle.sh: CLI must be set before sourcing}"
RUNNER="${RUNNER:-bash scripts/run_wasm_vibe_host_runner.sh}"
CTIMEOUT="${CTIMEOUT:-90}"
RTIMEOUT="${RTIMEOUT:-20}"

# GNU `timeout` is not on a stock macOS -- the BSD userland has no such
# command, and coreutils installs it as `gtimeout`. Resolved once here rather
# than assumed at each of the three call sites below.
#
# What it replaces, measured: with neither binary present every
# `timeout "$CTIMEOUT" ...` was a command-not-found -- 127, no wasm, no diag --
# so `compile` answered COMPILE_CRASH for every lane of every seed. A campaign
# on such a machine reports a compiler bug per generated program, and the
# stale-findings gate that runs this harness fails for a reason having nothing
# to do with what it checks (#2955 review).
#
# The fallback is a WATCHDOG, not "run it unbounded" -- the pattern
# scripts/test_vibe_library.sh uses for a test runner. Exit 124 is load-bearing
# HERE: it is the only thing separating COMPILE_HANG / RUN_HANG from a crash,
# so an unbounded lane deletes two finding classes from a differential oracle,
# and an actual hang never ends -- the campaign wedges instead of recording it.
# So bounded execution is kept on a machine with neither binary, in shell
# (#2955 review).
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
  # The fallback needs somewhere to put its per-call markers, and a marker it
  # could not allocate is not a smaller answer -- it is a WRONG one: the
  # watchdog would still kill at the deadline and then report the signal
  # status, so a compiler hang would be recorded as COMPILE_CRASH and a
  # runtime hang as RUN_TRAP (#2955 review). Allocated once, here, so an
  # invalid or unwritable TMPDIR is refused before any campaign begins rather
  # than per seed in the middle of one.
  WATCHDOG_DIR="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$WATCHDOG_DIR" ] || [ ! -d "$WATCHDOG_DIR" ]; then
    echo "[fuzz] no 'timeout' or 'gtimeout', and no writable temporary directory for the fallback" >&2
    echo "[fuzz] set TMPDIR to a writable directory, or install GNU coreutils (macOS: 'brew install coreutils')" >&2
    echo "[fuzz] refusing to measure: the fallback could not tell a hang from a crash" >&2
    exit 2
  fi
fi

# A `timeout`-compatible watchdog in POSIX shell, used only when neither
# binary exists. Contract kept identical to timeout(1) for the one thing the
# callers read: **124 means the bound was reached**, any other status is the
# command's own.
#
# The killed-vs-died distinction is taken from a MARKER the watchdog writes
# before signalling, not from the exit status. A child killed by SIGTERM
# reports 143 either way, so mapping 143 to 124 would report a program the OOM
# killer took as a HANG -- the wrong finding class, which is worse than none.
# With the marker, only a kill this function performed answers 124.
watchdog_run() { # <seconds> <cmd...>
  local secs="$1"; shift
  # The marker lives in the directory allocated when this fallback was
  # selected, so there is no per-call allocation to fail. It must NOT exist
  # yet: only the kill below creates it.
  local marker="${WATCHDOG_DIR:-}/wd.$$.$RANDOM"
  rm -f "$marker" 2>/dev/null
  local started
  started="$(date +%s)"
  # Job control is enabled around the launch so the child becomes a PROCESS
  # GROUP LEADER, and the signals below go to `-$cmd_pid` -- the whole group.
  # This is what timeout(1) does, and without it the bound does not bound:
  # measured, `watchdog_run 2 sh -c 'echo before; sleep 30'` answered 124 after
  # 30 SECONDS, because only the direct child was signalled while the real
  # workload kept running and held the command substitution's pipe open. Every
  # call site here spawns exactly that shape (`env ... bash runner ... node`).
  local had_monitor=0
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  (
    # stdout is closed off so this subshell never holds a command
    # substitution's pipe open past the child it is watching.
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    [ -n "$marker" ] && : > "$marker"
    kill -TERM "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
    sleep 2
    kill -KILL "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watch_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  kill "$watch_pid" 2>/dev/null
  wait "$watch_pid" 2>/dev/null
  if [ -e "$marker" ]; then
    rm -f "$marker"
    return 124
  fi
  rm -f "$marker" 2>/dev/null
  # Second line of defence, for the one case the marker cannot cover: the
  # filesystem filling mid-run, so the kill happened but writing the marker
  # did not. A status above 128 means the child died of a signal, and having
  # ALSO reached the bound is what separates that from a program the OOM
  # killer took early -- the case the marker exists to protect. Both
  # conditions, never either alone.
  local ended
  ended="$(date +%s)"
  if [ "$rc" -gt 128 ] && [ "$((ended - started))" -ge "$secs" ]; then
    return 124
  fi
  return "$rc"
}

# One spelling for the three call sites below, so which mechanism bounds them
# is decided once.
run_bounded() { # <seconds> <cmd...>
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$@"
  else
    watchdog_run "$@"
  fi
}

compile() { # src out extra-env...
  local src="$1" out="$2"; shift 2
  rm -f "$out" "$out.diag"
  run_bounded "$CTIMEOUT" env VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw "$@" \
    $RUNNER --invoke cli_main "$CLI" "$src" "$out" _start \
    > "$out.log" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then echo "COMPILE_HANG"; return; fi
  if [ -s "$out" ]; then echo "OK"; return; fi
  if [ -s "$out.diag" ]; then echo "COMPILE_DIAG"; return; fi
  echo "COMPILE_CRASH"
}

run_linear() { # wasm -> prints result or RUN_TRAP/RUN_HANG
  local wasm="$1"
  local out
  out=$(run_bounded "$RTIMEOUT" env VIBE_PREOPEN_DIR="$ROOT" \
    $RUNNER --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

run_gc() {
  local wasm="$1"
  local out
  out=$(run_bounded "$RTIMEOUT" wasmtime run -W gc=y,function-references=y,exceptions=y \
    --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

# classify DIR
#   DIR must contain single.vibe. If DIR also contains main.vibe (which
#   imports ./defs.vibe), the FS-linked lane is included too; otherwise it
#   is skipped (folded into the bump result so it can't spuriously mismatch).
#   Prints one line: "CLASS detail..." where CLASS is one of
#   OK / COMPILE_DIAG / COMPILE_CRASH / COMPILE_HANG / RUN_TRAP / RUN_HANG /
#   MISMATCH.
classify() {
  local dir="$1"
  local st_bump st_rc st_gc st_fs
  st_bump=$(compile "$dir/single.vibe" "$dir/bump.wasm" VIBE_RC=0)
  st_rc=$(compile "$dir/single.vibe" "$dir/rc.wasm" VIBE_RC=1)
  st_gc=$(compile "$dir/single.vibe" "$dir/gc.wasm" VIBE_RC=0 VIBE_BACKEND=gc)
  st_fs="OK"
  if [ -f "$dir/main.vibe" ]; then
    # FS compilation populates persistent source-list and source-group cache
    # files. Isolate them per candidate: deleting repository-global files
    # races when run_fuzz.sh runs multiple seeds concurrently.
    st_fs=$(compile "$dir/main.vibe" "$dir/fs.wasm" VIBE_RC=0 VIBE_FS_COMPILE=1 VIBE_BUILD_CACHE_DIR="$dir/cache")
  fi

  local bad="" pair lane st
  for pair in "bump:$st_bump" "rc:$st_rc" "gc:$st_gc" "fs:$st_fs"; do
    lane="${pair%%:*}"; st="${pair##*:}"
    if [ "$st" != "OK" ]; then bad="$bad $lane=$st"; fi
  done
  if [ -n "$bad" ]; then
    local cls
    cls=$(echo "$bad" | grep -oE "COMPILE_[A-Z]+" | sort -u | head -1)
    echo "$cls$bad"
    return
  fi

  local r_bump r_rc r_gc r_fs
  r_bump=$(run_linear "$dir/bump.wasm")
  r_rc=$(run_linear "$dir/rc.wasm")
  r_gc=$(run_gc "$dir/gc.wasm")
  r_fs="$r_bump"
  [ -f "$dir/main.vibe" ] && r_fs=$(run_linear "$dir/fs.wasm")

  case "$r_bump$r_rc$r_gc$r_fs" in
    *RUN_TRAP*) echo "RUN_TRAP bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; return ;;
    *RUN_HANG*) echo "RUN_HANG bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; return ;;
  esac
  if [ "$r_bump" != "$r_rc" ] || [ "$r_bump" != "$r_gc" ] || [ "$r_bump" != "$r_fs" ]; then
    echo "MISMATCH bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"
    return
  fi
  echo "OK bump=$r_bump"
}
