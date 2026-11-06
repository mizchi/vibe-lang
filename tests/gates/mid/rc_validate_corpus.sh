#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.

# 40rcv. `vibe rc-validate` over the RC fixture corpus (#3718 slice 1). Each
#        fixtures/rc_*.vibe file's Perceus plans are checked against the linear
#        ownership discipline by the public verb. A plan that releases a
#        reference it does not hold -- an over-release, a borrowed parameter
#        consumed without a dup, or a consume mark on an occurrence that does
#        not consume -- fails the gate: those are use-after-free shapes. A leak
#        line is the safe direction the planner accepts today (#705), so it is
#        counted and printed, not failed. A verb that errors fails too: an
#        unanswered file would read exactly like a clean one.
echo "[compiler-gate] 40rcv/40 rc-validate RC fixture corpus (#3718)"
gate_workdir rcvdir "_build/_gate_rc_validate"

# The failing line forms. One pattern, used by the corpus loop AND by the
# self-check below, so the check proves the loop's own filter can fail.
rcv_fatal_pattern=': (owned value released [0-9]+ more than held|borrowed parameter consumed without a dup|consume mark at offset -?[0-9]+ is not a consuming occurrence)$'

# Self-check first (#2248): the filter must reject each failing form and pass
# a leak, or a green corpus says nothing.
printf '%s\n' 'f x if1:then: owned value released 1 more than held' \
  'f p -: borrowed parameter consumed without a dup' \
  'f x -: consume mark at offset 12 is not a consuming occurrence' > "$rcvdir/red.txt"
if [ "$(grep -cE "$rcv_fatal_pattern" "$rcvdir/red.txt")" != 3 ]; then
  echo "[compiler-gate] FAIL: the rc-validate gate filter no longer matches every failing line form" >&2
  exit 1
fi
printf '%s\n' 'f x if1:else: owned value not consumed' 'f x -: not checked: loop' > "$rcvdir/green.txt"
if grep -qE "$rcv_fatal_pattern" "$rcvdir/green.txt"; then
  echo "[compiler-gate] FAIL: the rc-validate gate filter rejects a leak or a skip line" >&2
  exit 1
fi

rcv_files=0
rcv_leaks=0
rcv_skips=0
for rcv_f in fixtures/rc_*.vibe; do
  rcv_files=$((rcv_files + 1))
  rcv_status=0
  VIBE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" VIBE_CLI_WASM="$stage2_wasm" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" rc-validate "$rcv_f" \
    > "$rcvdir/out.txt" 2> "$rcvdir/err.txt" || rcv_status=$?
  if [ "$rcv_status" != 0 ]; then
    echo "[compiler-gate] FAIL: vibe rc-validate $rcv_f exited $rcv_status -- an unanswered file is not a clean one" >&2
    cat "$rcvdir/err.txt" "$rcvdir/out.txt" >&2
    exit 1
  fi
  if grep -qE "$rcv_fatal_pattern" "$rcvdir/out.txt"; then
    echo "[compiler-gate] FAIL: vibe rc-validate $rcv_f found a plan that releases more than it holds:" >&2
    grep -E "$rcv_fatal_pattern" "$rcvdir/out.txt" >&2
    exit 1
  fi
  rcv_leaks=$((rcv_leaks + $(grep -c ': owned value not consumed' "$rcvdir/out.txt" || true)))
  rcv_skips=$((rcv_skips + $(grep -c ': not checked: ' "$rcvdir/out.txt" || true)))
done
if [ "$rcv_files" = 0 ]; then
  echo "[compiler-gate] FAIL: no fixtures/rc_*.vibe file to validate" >&2
  exit 1
fi
rm -rf "$rcvdir"
echo "[compiler-gate] rc-validate corpus ok ($rcv_files files, $rcv_leaks leak lines, $rcv_skips not-checked lines)"
