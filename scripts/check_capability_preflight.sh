#!/usr/bin/env bash
# ADR-0088's L1 + L3, end to end (#2828, ADR-0088 Remaining/#2332).
#
# `preflight_instantiate` raised its message from the day it was written and
# was reachable from NOTHING but its unit test -- measured, zero production
# callers, and `--allow-*` existed only as the text inside that message. So the
# property this gate holds is not "the function is correct" (the unit tests in
# checker_entry_effect_test.vibe do that); it is that a RUN reaches it.
#
# Five cases, and the first is the one that matters most: with no flag the
# answer must be exactly what it was before the ladder was connected, or every
# existing program's authority changed silently.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
STAGE2="$(resolve_stage2 capability-preflight "${CAPABILITY_PREFLIGHT_STAGE2:-}")" || exit 1

WORK="$ROOT_DIR/_build/_capability_preflight"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PROG="$WORK/prog.vibex"
cat > "$PROG" <<'VIBE'
fn main() -> Unit allows Stdout + Fs::read_file {
  println("ok")
}
VIBE

pass=0; fail=0
ok()  { echo "capability-preflight: ok: $1"; pass=$((pass + 1)); }
bad() { echo "capability-preflight: FAIL: $1" >&2; fail=$((fail + 1)); }

# Each case runs the launcher with the resolved compiler and captures both
# streams; `run` exits non-zero on a refusal, so `|| true` keeps `set -e` from
# ending the gate at the first case that is SUPPOSED to fail.
run_case() {
  VIBE_CLI_WASM="$STAGE2" \
  VIBE_RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}" \
    bash "$ROOT_DIR/runtime/vibe" run "$@" "$PROG" 2>&1 || true
}

# 1. No flag: unchanged. A program that ran before must still run.
out="$(run_case)"
if printf '%s\n' "$out" | grep -q '^ok$'; then
  ok "no capability flag leaves the run exactly as it was"
else
  bad "an unflagged run must be unchanged; got: $out"
fi

# 2. A denied REQUIRED capability aborts, and the message names the edit --
#    both of them: the flag that grants it and the optional spelling.
out="$(run_case --deny-fs)"
if printf '%s\n' "$out" | grep -q 'not granted' \
   && printf '%s\n' "$out" | grep -q -- '--allow-fs' \
   && printf '%s\n' "$out" | grep -q 'allows Fs::read_file?'; then
  ok "a denied required capability aborts, naming both edits"
else
  bad "--deny-fs must abort naming --allow-fs and the optional spelling; got: $out"
fi

# 3. An allow-list that covers the entry's row still runs.
out="$(run_case --allow-fs --allow-stdout)"
if printf '%s\n' "$out" | grep -q '^ok$'; then
  ok "an allow-list covering the row runs"
else
  bad "--allow-fs --allow-stdout must run; got: $out"
fi

# 4. An allow-list is a LIST: naming one capability does not grant the others.
out="$(run_case --allow-stdout)"
if printf '%s\n' "$out" | grep -q 'not granted'; then
  ok "an allow-list that omits a required capability aborts"
else
  bad "--allow-stdout alone must abort on Fs::read_file; got: $out"
fi

# 5. Deny beats allow. Fail-closed is the only safe direction for this table,
#    and it is the one rule in the ladder that no document records -- so it is
#    pinned HERE rather than left to whoever reads the code next.
out="$(run_case --allow-fs --deny-fs)"
if printf '%s\n' "$out" | grep -q 'not granted'; then
  ok "--deny-* beats --allow-* for the same provider"
else
  bad "deny must beat allow; got: $out"
fi

# 6. A flag that is not a capability is refused rather than ignored: silently
#    accepting `--allow-nope` would read as a grant that was never made.
out="$(run_case --allow-nope)"
if printf '%s\n' "$out" | grep -q 'not a capability'; then
  ok "a non-capability --allow-* is refused, naming the providers"
else
  bad "--allow-nope must be refused; got: $out"
fi

echo "capability-preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
