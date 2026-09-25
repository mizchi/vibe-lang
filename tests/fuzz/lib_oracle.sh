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
  # Removed by the process that made it. tests/fuzz/reduce.py starts a fresh
  # classify.sh per oracle call and allows 4000 of them by default, so one
  # reduction would otherwise leave thousands of empty directories behind
  # (#2955 review). Neither consumer sets an EXIT trap of its own; if one ever
  # does, this line has to become part of it rather than replace it.
  trap 'rm -rf "$WATCHDOG_DIR"' EXIT
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
# The killed-vs-died distinction is taken from a MARKER, not from the exit
# status: a child killed by SIGTERM reports 143 either way, so mapping 143 to
# 124 would report a program the OOM killer took as a HANG -- the wrong finding
# class, which is worse than none.
#
# The marker is created HERE and REMOVED by the watchdog, which is the reverse
# of the obvious direction and is the point. Creating it is the operation that
# can fail (no directory, no space), and here a failure can be seen and said;
# unlinking cannot fail for lack of space, so the deadline path has nothing
# left to go wrong in. Written the other way round, a marker the watchdog
# could not create left the function reporting the signal status, so a hang
# was recorded as a crash (#2955 review).
#
# Wall-clock time is NOT consulted. An earlier version cross-checked "died of
# a signal AND ran at least `secs`", which sounds conservative and is not:
# `date +%s` has one-second resolution, so a program that kills itself at 1.2s
# under a 2s bound satisfies it whenever the boundary falls between the two
# reads. Measured, 2 runs in 8 of `watchdog_run 2 sh -c 'sleep 1.2; kill -TERM
# $$'` answered 124 -- a late crash recorded as a hang, intermittently, which
# is the worst possible shape for a differential oracle (#2955 review).
watchdog_run() { # <seconds> <cmd...>
  local secs="$1"; shift
  # The marker lives in the directory allocated when this fallback was
  # selected, so there is no per-call allocation to fail. It must NOT exist
  # yet: only the kill below creates it.
  # Allocated ATOMICALLY, not composed from `$$` and `$RANDOM`. Seeds run as
  # background subshells, which share the shell's `$$`, so the name rested on
  # 15 bits of `$RANDOM` -- and a subshell in bash 3.2 (what macOS ships, the
  # platform this fallback exists for) inherits the parent's RANDOM sequence,
  # which makes the collision systematic rather than merely likely. Two calls
  # sharing a name is not a lost answer but a WRONG one: the first to finish
  # removes the shared marker, and the second reads its absence as its own
  # bound and reports COMPILE_HANG / RUN_HANG for a program that completed
  # normally (#2955 review).
  #
  # mktemp both creates and guarantees uniqueness in one step, and its failure
  # is the creation failure handled below -- the same check, one fewer thing
  # to get right.
  local marker
  marker="$(mktemp "${WATCHDOG_DIR:-/nonexistent}/wd.XXXXXXXX" 2>/dev/null || true)"
  if [ -z "$marker" ] || [ ! -f "$marker" ]; then
    # Loud, not silent: without a marker this function cannot tell a bound
    # from a crash, and guessing is what the whole mechanism exists to avoid.
    # 125 is timeout(1)'s own "the timeout itself failed" status, and every
    # caller below PROPAGATES it up to run_seed, which ends the seed without
    # writing a completion stamp -- so the campaign refuses.
    #
    # This was `exit 125`, with a comment claiming it ended the seed. It did
    # not: `compile` is called as `st=$(compile ...)`, so the exit ended only
    # that command substitution. Measured, a campaign whose marker allocation
    # fails recorded `seed_1_` with an EMPTY class and `bump= rc= gc= fs=`,
    # then reported `2 seeds, 2 findings` -- fabricated compiler bugs from a
    # broken watchdog, which is the one outcome this file must never produce
    # (#2955 review).
    echo "[fuzz] watchdog could not create its marker in ${WATCHDOG_DIR:-<unset>}" >&2
    echo "[fuzz] refusing to bound this command: a hang could not be told from a crash" >&2
    return 125
  fi
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
    # Remove, do not create: unlinking needs no free space, so the bound is
    # recorded even on a filesystem that has filled since the marker was made.
    rm -f "$marker" 2>/dev/null
    kill -TERM "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
    sleep 2
    kill -KILL "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watch_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  # WHICH of the two ended first decides what to do with the watcher, and the
  # marker answers that: it is still there only if the watchdog never fired.
  if [ -e "$marker" ]; then
    # Never fired -- the command finished on its own. Cancel the poll.
    kill "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
    rm -f "$marker" 2>/dev/null
    return "$rc"
  fi
  # It fired. Let it FINISH its TERM -> KILL escalation instead of cancelling
  # it: `wait` returns as soon as the group LEADER dies, and a descendant that
  # ignores SIGTERM outlives it while still holding the command
  # substitution's stdout pipe. Killing the watcher here left nothing to send
  # the SIGKILL, so the call waited for that descendant -- measured, a 1s
  # bound around a leader that exits on TERM with a TERM-ignoring child took
  # the child's full 8 seconds. A bound that answers 124 after eight seconds
  # is not a bound (#2955 review). The escalation is capped at ~2s by the
  # watchdog itself, and only runs when the bound has already been reached.
  wait "$watch_pid" 2>/dev/null
  return 124
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
  # The watchdog could not bound this command. Say nothing classifiable and
  # hand the status up: a lane with no verdict is not a finding.
  if [ $rc -eq 125 ]; then return 125; fi
  if [ $rc -eq 124 ]; then echo "COMPILE_HANG"; return; fi
  if [ -s "$out" ]; then echo "OK"; return; fi
  if [ -s "$out.diag" ]; then echo "COMPILE_DIAG"; return; fi
  echo "COMPILE_CRASH"
}

# Both runners keep the lane's WHOLE stdout in "$wasm.out" and print only its
# last line, stripped, as the lane's result. The last line is the value
# `_start` returned; the lines above it are what the program printed, which
# is what the lane-independent oracle (oracle_diff, #2979) reads.
run_linear() { # wasm -> prints result or RUN_TRAP/RUN_HANG
  local wasm="$1"
  local out
  out=$(run_bounded "$RTIMEOUT" env VIBE_PREOPEN_DIR="$ROOT" \
    $RUNNER --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  printf '%s\n' "$out" > "$wasm.out" 2>/dev/null
  if [ $rc -eq 125 ]; then return 125; fi
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
  printf '%s\n' "$out" > "$wasm.out" 2>/dev/null
  if [ $rc -eq 125 ]; then return 125; fi
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

# ---------- lane-independent oracle (#2979) ----------
#
# A differential oracle cannot see a wrong answer every lane shares, and the
# 2026-09 audit's P0s were all of that shape. `gen_program.py --extended`
# therefore prints, for each value it knows at generation time, one line
# `<ID>|<text>` and writes the text it must be into `expected.txt`. The ID's
# first letter names the oracle and so the finding class:
#
#   R -> ORACLE_RENDER   a value built from literals, a builtin result, a
#                        labeled / generic call, a shift count
#   T -> ORACLE_THROW    `throw(K(..))` under `handle .. with Exception[K]`
#   C -> ORACLE_CONT     a handler arm's answer, resuming or leaving
#
# Lines are matched by ID, not by position, so tests/fuzz/reduce.py can drop
# statements (it drops the matching expected lines with them) without the
# remaining lines shifting into a false mismatch.

# oracle_diff EXPECTED OUT -> "ID<TAB>expected<TAB>got" for the first ID
# whose printed text differs from (or is absent in) OUT; nothing when all
# agree.
oracle_diff() {
  awk 'NR == FNR {
         i = index($0, "|"); if (i == 0) next
         id = substr($0, 1, i - 1); want[id] = substr($0, i + 1); order[++n] = id
         next
       }
       {
         i = index($0, "|"); if (i == 0) next
         id = substr($0, 1, i - 1)
         if ((id in want) && !(id in got)) got[id] = substr($0, i + 1)
       }
       END {
         for (k = 1; k <= n; k++) {
           id = order[k]
           if (!(id in got)) { printf "%s\t%s\t<missing>\n", id, want[id]; exit }
           if (got[id] != want[id]) { printf "%s\t%s\t%s\n", id, want[id], got[id]; exit }
         }
       }' "$1" "$2"
}

# oracle_failing EXPECTED OUT -> every failing ID, one per line. The verdict
# names the FIRST failure; this list rides along in the detail so one bug
# that fires in most programs does not hide the others in a campaign count.
oracle_failing() {
  awk 'NR == FNR {
         i = index($0, "|"); if (i == 0) next
         id = substr($0, 1, i - 1); want[id] = substr($0, i + 1); order[++n] = id
         next
       }
       {
         i = index($0, "|"); if (i == 0) next
         id = substr($0, 1, i - 1)
         if ((id in want) && !(id in got)) got[id] = substr($0, i + 1)
       }
       END {
         for (k = 1; k <= n; k++) {
           id = order[k]
           if (!(id in got) || got[id] != want[id]) print id
         }
       }' "$1" "$2"
}

# oracle_line ID OUT -> the text lane OUT printed for ID (or <missing>)
oracle_line() {
  awk -v id="$1" 'BEGIN { found = 0 }
       { i = index($0, "|"); if (i == 0) next
         if (substr($0, 1, i - 1) == id) { print substr($0, i + 1); found = 1; exit } }
       END { if (!found) print "<missing>" }' "$2"
}

oracle_class_of() { # ID -> finding class
  case "$1" in
    T*) echo "ORACLE_THROW" ;;
    C*) echo "ORACLE_CONT" ;;
    *) echo "ORACLE_RENDER" ;;
  esac
}

# ---------- diagnostic quality (#2979, mutation mode) ----------
#
# `--mutate` used to accept ANY diagnostic as the expected rejection, so a
# diagnostic with no position, or one naming a token the user never wrote,
# passed as a success. Both are now findings of their own:
#
#   DIAG_NO_LOCATION     the diagnostic carries no `line N:M` anywhere
#   DIAG_INTERNAL_TOKEN  it reports an unexpected separator (`;` `,` `:`
#                        brackets) that the source does not contain -- a
#                        token the compiler synthesized, not one it read
#
# diag_class DIAG SRC -> prints one of the two classes, or nothing when the
# diagnostic is well-formed.
diag_class() {
  local diag="$1" src="$2"
  if ! grep -qE 'line [0-9]+:[0-9]+' "$diag" 2>/dev/null; then
    echo "DIAG_NO_LOCATION"
    return
  fi
  local tok
  # What follows the last ": " on an "unexpected ..." line is the token the
  # compiler says it met; quotes around it are the message's, not the token's.
  while IFS= read -r tok; do
    case "$tok" in
      ';'|','|':'|'('|')'|'['|']'|'{'|'}')
        if ! grep -qF -- "$tok" "$src" 2>/dev/null; then
          echo "DIAG_INTERNAL_TOKEN"
          return
        fi ;;
    esac
  done <<EOT
$(grep -i 'unexpected' "$diag" 2>/dev/null | sed -e 's/.*: //' -e 's/[[:space:]]*$//' \
    -e "s/^['\`\"]\(.*\)['\`\"]\$/\1/")
EOT
}

# classify_mutant SRC OUT -> the mutation-mode verdict for one input:
# OK, COMPILE_DIAG (a well-formed rejection), DIAG_NO_LOCATION,
# DIAG_INTERNAL_TOKEN, COMPILE_CRASH or COMPILE_HANG. Returns 125 like
# `compile` when the watchdog could not bound the compiler.
classify_mutant() {
  local src="$1" out="$2" st
  st=$(compile "$src" "$out" VIBE_RC=0) || [ $? -ne 125 ] || return 125
  if [ "$st" = "COMPILE_DIAG" ]; then
    local dc
    dc=$(diag_class "$out.diag" "$src")
    [ -z "$dc" ] || st="$dc"
  fi
  echo "$st"
}

# lane_skipped DIR LANE -- true when DIR/skip_lanes names LANE. A generated
# program that uses a construct one lane cannot compile today (trait impls on
# the flat single-source bump/RC lane) says so there, so the other lanes still
# measure it; the skip is reported in the verdict rather than hidden.
lane_skipped() {
  [ -f "$1/skip_lanes" ] || return 1
  grep -qwF -- "$2" "$1/skip_lanes"
}

# classify DIR
#   DIR must contain single.vibe. If DIR also contains main.vibe (which
#   imports ./defs.vibe), the FS-linked lane is included too; otherwise it
#   is skipped (folded into the reference result so it can't spuriously
#   mismatch). Lanes named in DIR/skip_lanes are not compiled and report
#   `skipped`. If DIR contains expected.txt, every lane's printed output is
#   also checked against it (the oracle above).
#   Prints one line: "CLASS detail..." where CLASS is one of
#   OK / COMPILE_DIAG / COMPILE_CRASH / COMPILE_HANG / RUN_TRAP / RUN_HANG /
#   MISMATCH / ORACLE_RENDER / ORACLE_THROW / ORACLE_CONT.
classify() {
  local dir="$1"
  local st_bump=skipped st_rc=skipped st_gc=skipped st_fs=skipped
  # Each lane's STATUS is checked, not just its output: 125 means the watchdog
  # could not bound that command, and an unbounded lane has no verdict to
  # contribute. Propagated rather than folded into `bad`, so the seed refuses
  # instead of recording a finding with an empty class.
  if ! lane_skipped "$dir" bump; then
    st_bump=$(compile "$dir/single.vibe" "$dir/bump.wasm" VIBE_RC=0) || [ $? -ne 125 ] || return 125
  fi
  if ! lane_skipped "$dir" rc; then
    st_rc=$(compile "$dir/single.vibe" "$dir/rc.wasm" VIBE_RC=1) || [ $? -ne 125 ] || return 125
  fi
  if ! lane_skipped "$dir" gc; then
    st_gc=$(compile "$dir/single.vibe" "$dir/gc.wasm" VIBE_RC=0 VIBE_BACKEND=gc) || [ $? -ne 125 ] || return 125
  fi
  local has_fs=0
  if [ -f "$dir/main.vibe" ] && ! lane_skipped "$dir" fs; then
    has_fs=1
    # FS compilation populates persistent source-list and source-group cache
    # files. Isolate them per candidate: deleting repository-global files
    # races when run_fuzz.sh runs multiple seeds concurrently.
    st_fs=$(compile "$dir/main.vibe" "$dir/fs.wasm" VIBE_RC=0 VIBE_FS_COMPILE=1 VIBE_BUILD_CACHE_DIR="$dir/cache") || [ $? -ne 125 ] || return 125
  fi

  local bad="" pair lane st
  for pair in "bump:$st_bump" "rc:$st_rc" "gc:$st_gc" "fs:$st_fs"; do
    lane="${pair%%:*}"; st="${pair##*:}"
    if [ "$st" != "OK" ] && [ "$st" != "skipped" ]; then bad="$bad $lane=$st"; fi
  done
  if [ -n "$bad" ]; then
    local cls
    cls=$(echo "$bad" | grep -oE "COMPILE_[A-Z]+" | sort -u | head -1)
    echo "$cls$bad"
    return
  fi

  local r_bump=skipped r_rc=skipped r_gc=skipped r_fs=skipped
  if [ "$st_bump" = OK ]; then r_bump=$(run_linear "$dir/bump.wasm") || [ $? -ne 125 ] || return 125; fi
  if [ "$st_rc" = OK ]; then r_rc=$(run_linear "$dir/rc.wasm") || [ $? -ne 125 ] || return 125; fi
  if [ "$st_gc" = OK ]; then r_gc=$(run_gc "$dir/gc.wasm") || [ $? -ne 125 ] || return 125; fi
  if [ "$has_fs" -eq 1 ]; then
    r_fs=$(run_linear "$dir/fs.wasm") || [ $? -ne 125 ] || return 125
  fi

  case "$r_bump$r_rc$r_gc$r_fs" in
    *RUN_TRAP*) echo "RUN_TRAP bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; return ;;
    *RUN_HANG*) echo "RUN_HANG bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; return ;;
  esac

  # The reference is the first lane that ran. A lane that did not run (a
  # skip) reports `skipped` and is left out of the comparison; with no FS
  # split at all the FS lane is folded into the reference, as before.
  local ref="" ref_lane="" v
  for pair in "bump:$r_bump" "rc:$r_rc" "gc:$r_gc" "fs:$r_fs"; do
    lane="${pair%%:*}"; v="${pair#*:}"
    if [ "$v" != "skipped" ]; then ref="$v"; ref_lane="$lane"; break; fi
  done
  [ -f "$dir/main.vibe" ] || r_fs="$ref"
  for pair in "bump:$r_bump" "rc:$r_rc" "gc:$r_gc" "fs:$r_fs"; do
    v="${pair#*:}"
    if [ "$v" != "skipped" ] && [ "$v" != "$ref" ]; then
      echo "MISMATCH bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"
      return
    fi
  done

  if [ -f "$dir/expected.txt" ]; then
    local d id want detail l2 v2 pair2 tab
    tab=$(printf '\t')
    for pair in "bump:$r_bump" "rc:$r_rc" "gc:$r_gc" "fs:$r_fs"; do
      lane="${pair%%:*}"; v="${pair#*:}"
      [ "$v" != "skipped" ] || continue
      [ "$lane" != fs ] || [ "$has_fs" -eq 1 ] || continue
      d=$(oracle_diff "$dir/expected.txt" "$dir/$lane.wasm.out")
      [ -n "$d" ] || continue
      id="${d%%"$tab"*}"
      want="${d#*"$tab"}"; want="${want%%"$tab"*}"
      detail="id=$id expected='$want'"
      for pair2 in "bump:$r_bump" "rc:$r_rc" "gc:$r_gc" "fs:$r_fs"; do
        l2="${pair2%%:*}"; v2="${pair2#*:}"
        if [ "$v2" = "skipped" ]; then
          detail="$detail $l2=skipped"
        elif [ "$l2" = fs ] && [ "$has_fs" -eq 0 ]; then
          detail="$detail $l2=none"
        else
          detail="$detail $l2='$(oracle_line "$id" "$dir/$l2.wasm.out")'"
        fi
      done
      local all="" l3 v3 pair3
      for pair3 in "bump:$r_bump" "rc:$r_rc" "gc:$r_gc" "fs:$r_fs"; do
        l3="${pair3%%:*}"; v3="${pair3#*:}"
        [ "$v3" != "skipped" ] || continue
        [ "$l3" != fs ] || [ "$has_fs" -eq 1 ] || continue
        all="$all $(oracle_failing "$dir/expected.txt" "$dir/$l3.wasm.out" | tr '\n' ' ')"
      done
      all=$(printf '%s\n' $all | sort -u | tr '\n' ',' | sed 's/,$//')
      echo "$(oracle_class_of "$id") $detail failing=$all"
      return
    done
  fi
  echo "OK $ref_lane=$ref"
}
