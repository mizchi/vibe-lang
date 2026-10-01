#!/usr/bin/env bash
# Red/green for scripts/run_bounded.sh (#2958).
#
# The helper is what every bounded call in scripts/ and tests/ now goes
# through, and its fallback watchdog is the path nobody on Linux exercises by
# accident -- CI has GNU timeout, so a broken watchdog would stay green there
# and fail only on the macOS machine it exists for. So the watchdog is forced
# (VIBE_RUN_BOUNDED_IMPL=watchdog) and held to timeout(1)'s contract, and each
# property is then shown to FAIL on a mutant carrying the wrong shape, per the
# #2248 rule that a check nobody has seen fail is a filename.
set -euo pipefail

# #2252: inherit nothing the helper reads. That includes the helper ITSELF:
# the gate lanes source run_bounded.sh (tests/gates/lib.sh), which exports the
# functions into this process's environment, and an inherited export would
# satisfy the xargs-worker rung for a mutant that never exports them.
unset VIBE_RUN_BOUNDED_IMPL
unset -f run_bounded run_bounded_watchdog run_bounded_monotonic_seconds 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/run_bounded.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_run_bounded_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "run-bounded self-test: FAIL: $1" >&2; exit 1; }
ok() { echo "  ok  $1"; }

# Realtime can step while WSL is running. Measure elapsed time independently
# so a backwards step cannot hide a grandchild that outlives the watchdog.
monotonic_seconds() {
  node -p '(process.hrtime.bigint() / 1000000000n).toString()'
}

# One contract, asked of a given copy of the helper under a given mechanism.
# Prints the name of every rung that does not hold; empty output = all hold.
# Each rung runs in its own `bash`, so a mutant that aborts one cannot take
# the others down with it.
contract() { # <lib> <impl>
  local lib="$1" impl="$2"
  local r
  # 1. The command's own status passes through.
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; run_bounded 10 sh -c "exit 3"; echo "rc=$?"' _ "$lib" 2>/dev/null | tail -1)"
  [ "$r" = "rc=3" ] || echo "status: $r"
  # 2. Reaching the bound answers 124, and does so promptly even when the real
  #    workload is a GRANDCHILD (the wrapper shape of nearly every call site):
  #    signalling only the direct child left the grandchild holding the
  #    substitution's pipe open until it finished on its own.
  local t0 t1
  t0="$(monotonic_seconds)"
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; out="$(run_bounded 1 bash -c "sh -c \"sleep 9\"; true")" && echo "rc=0" || echo "rc=$?"' _ "$lib" 2>/dev/null | tail -1)"
  t1="$(monotonic_seconds)"
  [ "$r" = "rc=124" ] || echo "bound: $r"
  [ $((t1 - t0)) -lt 7 ] || echo "grandchild: took $((t1 - t0))s for a 1s bound"
  # 3. A command that dies of SIGTERM on its OWN is not a timeout. Mapping
  #    143 to 124 from the status relabels a crash (or the OOM killer) as a
  #    hang; only the marker knows who sent the signal.
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; run_bounded 10 sh -c "kill -TERM \$\$"; echo "rc=$?"' _ "$lib" 2>/dev/null | tail -1)"
  [ "$r" = "rc=143" ] || echo "self-kill: $r"
  # 3b. A command that IGNORES SIGTERM is still ended: timeout(1) without
  #     `-k` sends TERM and waits forever (#3099 review).
  t0="$(monotonic_seconds)"
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; run_bounded 1 sh -c "trap \"\" TERM; sleep 20"; echo "rc=$?"' _ "$lib" 2>/dev/null | tail -1)"
  t1="$(monotonic_seconds)"
  [ $((t1 - t0)) -lt 10 ] || echo "term-ignoring: took $((t1 - t0))s for a 1s bound ($r)"
  #     ...and it still answers 124: timeout(1) exits 137 after its own KILL
  #     escalation, which reads as a crash to a caller classifying hangs.
  [ "$r" = "rc=124" ] || echo "term-ignoring status: $r"
  # 3c. A real SIGKILL shortly BEFORE the bound stays 137, even when whole-
  #     second arithmetic rounds its elapsed time up to the bound.
  local k
  for k in 1 2 3; do
    r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; run_bounded 2 bash -c "sleep 1.6; kill -KILL \$\$"; echo "rc=$?"' _ "$lib" 2>/dev/null | tail -1)"
    [ "$r" = "rc=137" ] || { echo "early-kill: $r"; break; }
  done
  # 4. Assignment prefixes and stdin reach the command, as they do through
  #    timeout(1): `VAR=x timeout 60 cmd <in` was the commonest call shape.
  r="$(printf 'piped\n' | VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; PROBE_VAR=seen run_bounded 10 sh -c "read -r l; echo \"\$PROBE_VAR/\$l\""' _ "$lib" 2>/dev/null | tail -1)"
  [ "$r" = "seen/piped" ] || echo "env+stdin: $r"
  # 5. A caller under `set -e` survives a failing command it checks.
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c 'set -euo pipefail; . "$1"; run_bounded 10 false || echo "checked=$?"; echo after' _ "$lib" 2>/dev/null | tr '\n' ' ')"
  [ "$r" = "checked=1 after " ] || echo "set-e: $r"
  # 6. An `xargs ... bash -c` worker sees the function (unit_test_runner.sh,
  #    vibe_test.sh, parallel_warm_pool.sh and doctest_extract_run.sh call it
  #    from one). Unexported, it is exit 127 again.
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; echo x | xargs -I{} bash -c "run_bounded 10 echo worker-{}"' _ "$lib" 2>/dev/null | tail -1)"
  [ "$r" = "worker-x" ] || echo "xargs-worker: $r"
  # 7. Executed rather than sourced, for command strings (vibe_md.vibex).
  r="$(VIBE_RUN_BOUNDED_IMPL="$impl" bash "$lib" 1 sleep 5 >/dev/null 2>&1 && echo rc=0 || echo "rc=$?")"
  [ "$r" = "rc=124" ] || echo "executed: $r"
}

# --- green: the real helper, under every mechanism this machine can offer.
impls="watchdog"
command -v timeout >/dev/null 2>&1 && impls="$impls timeout"
command -v gtimeout >/dev/null 2>&1 && impls="$impls gtimeout"
for impl in $impls; do
  broken="$(contract "$LIB" "$impl")"
  [ -z "$broken" ] || fail "the real helper breaks the contract under $impl: $broken"
  ok "the real helper keeps timeout(1)'s contract under $impl"
done

# --- the edges the contract rungs do not reach.
r="$(bash -c '. "$1"; run_bounded 0 sh -c "exit 5"; echo "rc=$?"' _ "$LIB" 2>/dev/null | tail -1)"
[ "$r" = "rc=5" ] || fail "a 0 bound did not run the command unbounded: $r"
r="$(bash -c '. "$1"; run_bounded 1.5 true; echo "rc=$?"' _ "$LIB" 2>/dev/null | tail -1)"
[ "$r" = "rc=125" ] || fail "a non-integer bound was not refused: $r"
out="$(TMPDIR="$WORK/does-not-exist" VIBE_RUN_BOUNDED_IMPL=watchdog bash -c '. "$1"; run_bounded 5 true; echo "rc=$?"' _ "$LIB" 2>&1)"
case "$out" in
  *"could not create its marker"*"rc=125"*) ;;
  *) fail "a watchdog with no marker did not refuse loudly: $out" ;;
esac
ok "0 = unbounded, a fractional bound is refused, and a watchdog with no marker refuses (125) rather than guessing"

# --- red: each property fails on a mutant carrying the wrong shape. Every
# mutation is checked to have LANDED before its verdict is believed.
mutant() { # <name> <sed-expr> <marker-text-that-must-appear>
  local m="$WORK/$1.sh"
  sed "$2" "$LIB" > "$m"
  grep -qF -- "$3" "$m" || fail "mutant $1 did not land"
  printf '%s' "$m"
}

# The status-based guess the three local run_with_timeout copies made.
m="$(mutant status_guess 's/^  if \[ -e "\$marker" \]; then$/  if [ "$rc" -ne 143 ] \&\& [ "$rc" -ne 137 ]; then/' 'if [ "$rc" -ne 143 ]')"
broken="$(contract "$m" watchdog)"
case "$broken" in *self-kill*) ok "red: deciding killed-vs-died from the status relabels a self-kill as 124" ;;
  *) fail "the status-guess mutant was not caught: ${broken:-<no rung failed>}" ;; esac

# Signalling the direct child only, not its process group.
m="$(mutant child_only 's/kill -TERM "-\$cmd_pid" 2>\/dev\/null || //; s/kill -KILL "-\$cmd_pid" 2>\/dev\/null || //' 'kill -TERM "$cmd_pid" 2>/dev/null')"
grep -qF -- 'kill -TERM "-$cmd_pid"' "$m" && fail "mutant child_only still signals the group"
broken="$(contract "$m" watchdog)"
case "$broken" in *grandchild*) ok "red: signalling only the direct child lets the grandchild outlive the bound" ;;
  *) fail "the child-only mutant was not caught: ${broken:-<no rung failed>}" ;; esac

# Realtime backsteps must not hide that same child-only defect. Keep a
# wall-clock control to prove this probe catches the old false negative.
clock_dir="$WORK/clock"
mkdir -p "$clock_dir"
cat > "$clock_dir/date" <<'CLOCKEOF'
#!/usr/bin/env bash
if [ -s "${VIBE_FAKE_REALTIME_STATE:?}" ]; then
  printf '0\n'
else
  printf '1000000\n'
  printf 'stepped\n' > "$VIBE_FAKE_REALTIME_STATE"
fi
CLOCKEOF
chmod +x "$clock_dir/date"
clock_state="$clock_dir/state"
[ "$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" date +%s)" = 1000000 ] || fail "fake clock did not start"
[ "$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" date +%s)" = 0 ] || fail "fake clock did not backstep"
: > "$clock_state"
clock_probe="$WORK/clock-probe.sh"
sed '/^# --- green:/,$d' "$SCRIPT_DIR/run_bounded_test.sh" > "$clock_probe"
printf 'contract "$1" watchdog\n' >> "$clock_probe"
broken="$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" bash "$clock_probe" "$LIB")"
[ -z "$broken" ] || fail "the real helper fails under a realtime backstep: $broken"
broken="$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" bash "$clock_probe" "$m")"
case "$broken" in *grandchild*) ;;
  *) fail "the realtime backstep hid the child-only mutant: ${broken:-<no rung failed>}" ;; esac
clock_control="$WORK/clock-control.sh"
sed 's/t0="$(monotonic_seconds)"/t0="$(date +%s)"/; s/t1="$(monotonic_seconds)"/t1="$(date +%s)"/' "$clock_probe" > "$clock_control"
[ "$(grep -cF '="$(date +%s)"' "$clock_control")" = 4 ] || fail "the wall-clock mutation did not land on all four readings"
: > "$clock_state"
broken="$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" bash "$clock_control" "$m")"
[ -z "$broken" ] || fail "the wall-clock control did not reproduce the hidden defect: $broken"
ok "red: wall-clock backsteps hide a child-only watchdog; monotonic timing detects it"

# The GNU timeout path also distinguishes escalation from an early SIGKILL.
# Its own timer must stay independent of the realtime clock, not just the
# self-test's elapsed-time assertions.
wall_lib="$WORK/wall-clock-lib.sh"
sed 's/start="$(run_bounded_monotonic_seconds)"/start="$(date +%s)"/; s/end="$(run_bounded_monotonic_seconds)"/end="$(date +%s)"/' "$LIB" > "$wall_lib"
[ "$(grep -cF '="$(date +%s)"' "$wall_lib")" = 2 ] || fail "the timeout(1) wall-clock mutation did not land"
for impl in $impls; do
  [ "$impl" != watchdog ] || continue
  : > "$clock_state"
  broken="$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" contract "$LIB" "$impl")"
  [ -z "$broken" ] || fail "the real $impl helper fails under a realtime backstep: $broken"
  : > "$clock_state"
  r="$(VIBE_FAKE_REALTIME_STATE="$clock_state" PATH="$clock_dir:$PATH" VIBE_RUN_BOUNDED_IMPL="$impl" bash -c '. "$1"; run_bounded 1 sh -c "trap \"\" TERM; sleep 20"; echo "rc=$?"' _ "$wall_lib" 2>/dev/null | tail -1)"
  [ "$r" = rc=137 ] || fail "the $impl wall-clock control did not reproduce misclassification: $r"
  ok "red: $impl escalation survives a realtime backstep; its wall-clock mutant returns 137"
done

# Linux's cheap clock and the portable Node clock must give the same timeout
# contract. If neither clock is available, the existing marker watchdog is
# selected before launching the command.
node_lib="$WORK/node-clock-lib.sh"
sed 's/if \[ -r \/proc\/uptime \]; then/if false; then/' "$LIB" > "$node_lib"
grep -qF 'if false; then' "$node_lib" || fail "the Node clock probe did not land"
if command -v timeout >/dev/null 2>&1; then
  r="$(VIBE_RUN_BOUNDED_IMPL="timeout" bash -c '. "$1"; run_bounded 1 sh -c "trap \"\" TERM; sleep 20"; echo "rc=$?"' _ "$node_lib" 2>/dev/null | tail -1)"
  [ "$r" = rc=124 ] || fail "the Node clock misclassified escalation: $r"
  r="$(VIBE_RUN_BOUNDED_IMPL="timeout" bash -c '. "$1"; run_bounded_monotonic_seconds() { return 1; }; run_bounded_watchdog() { return 42; }; run_bounded 1 true; echo "rc=$?"' _ "$LIB" 2>/dev/null | tail -1)"
  [ "$r" = rc=42 ] || fail "a missing monotonic clock did not select the watchdog: $r"
  ok "Node clock classifies escalation; an unavailable clock selects the marker watchdog"
fi

# Defined but not exported.
m="$(mutant no_export 's/^export -f run_bounded run_bounded_watchdog$/: not exported/' ': not exported')"
broken="$(contract "$m" watchdog)"
case "$broken" in *xargs-worker*) ok "red: an unexported helper is command-not-found in an xargs worker" ;;
  *) fail "the no-export mutant was not caught: ${broken:-<no rung failed>}" ;; esac

echo "[run-bounded-test] ok"
