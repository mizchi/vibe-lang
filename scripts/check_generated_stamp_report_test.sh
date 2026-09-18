#!/usr/bin/env bash
# Red test for check_generated_stamp_report.sh (#2248: a gate means nothing
# until it is known to be able to fail).
#
# Three cases. RED 1 and RED 2 mutate the gate's input and assert it rejects;
# RED 0 comes first and is not a mutation at all -- it DEMONSTRATES the abort in
# a standalone harness, so the reason the token matters is measured here rather
# than asserted in a comment. Without it this file would only prove that a
# scanner can find the word `head`.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252).
unset VIBE_GENERATED_STAMP_REPORT_ROOT
unset VIBE_GENERATED_STAMP_REPORT_TARGET

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_genstamp_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[generated-stamp-report-test] FAIL: $*" >&2; exit 1; }

run_gate() { # run_gate <target>
  VIBE_GENERATED_STAMP_REPORT_TARGET="$1" \
    bash scripts/check_generated_stamp_report.sh >"$WORK/out" 2>&1
}

# GREEN control. Without it a gate failing for an unrelated reason would make
# every red case below "pass".
if ! run_gate scripts/ensure_generated.sh; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the real script; the red cases below would prove nothing"
fi

# RED 0: the hazard itself, measured. Two scripts differing in ONE token, each
# given a diff large enough to exceed the pipe buffer. The `head` one must abort
# before its last line; the `sed -n 1,20p` one must reach it.
#
# The payload is sized from the pipe buffer (64KiB on Linux), with margin: the
# whole point is that the writer is still writing when the reader leaves.
cat > "$WORK/gen_payload.sh" <<'PAYLOAD'
i=0
while [ "$i" -lt 4000 ]; do
  printf 'line %04d %s\n' "$i" "0123456789012345678901234567890123456789012345678901234567890123456789"
  i=$((i + 1))
done
PAYLOAD
payload="$(bash "$WORK/gen_payload.sh")"
payload_bytes="$(printf '%s\n' "$payload" | wc -c)"
[ "$payload_bytes" -gt 131072 ] \
  || fail "RED 0 payload is only $payload_bytes bytes; it must exceed the pipe buffer to signal SIGPIPE"

for reader in "head -20" "sed -n '1,20p'"; do
  cat > "$WORK/harness.sh" <<HARNESS
set -euo pipefail
diff_out="\$(bash "$WORK/gen_payload.sh")"
printf '%s\n' "\$diff_out" | $reader >/dev/null
echo REACHED_THE_END
HARNESS
  harness_out="$(bash "$WORK/harness.sh" 2>/dev/null || true)"
  case "$reader" in
    "head -20")
      [ "$harness_out" != "REACHED_THE_END" ] \
        || fail "RED 0: 'head -20' did NOT abort the script; the hazard this gate is about is not reproducible here, so the gate guards nothing"
      ;;
    *)
      [ "$harness_out" = "REACHED_THE_END" ] \
        || fail "RED 0: the draining reader ALSO aborted; the fix does not fix it"
      ;;
  esac
done

# RED 1: the reader put back. The gate must reject its own script's real shape
# with only that token changed.
sed "s@| sed -n '1,20p' >&2@| head -20 >\&2@" scripts/ensure_generated.sh > "$WORK/head.sh"
grep -qF '| head -20 >&2' "$WORK/head.sh" \
  || fail "RED 1 mutation did not land (the reader was not rewritten)"
if run_gate "$WORK/head.sh"; then
  fail "RED 1: the gate accepted a report piping into 'head' (it is not checking the reader)"
fi
grep -qF 'closes early' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 2: no report at all. Silence is "unchecked", not "clean" -- a gate that
# passes a script it never found is the shape #2248 is about.
grep -v '\$diff_out' scripts/ensure_generated.sh > "$WORK/gone.sh"
if grep -q '\$diff_out' "$WORK/gone.sh"; then
  fail "RED 2 mutation did not land (a \$diff_out line survived)"
fi
if run_gate "$WORK/gone.sh"; then
  fail "RED 2: the gate passed a script with no report pipeline at all"
fi
grep -qF 'no $diff_out pipeline found' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

echo "[generated-stamp-report-test] ok (the abort demonstrated, 2 red cases, each mutation verified to land)"
