#!/usr/bin/env bash
# Red test for check_telemetry_sidecar_guards.sh (#2248): the gate must be
# able to FAIL, on a real compiler rather than a stub.
#
# The mutation is the COMMITTED SEED. It predates FS-lane telemetry entirely,
# so it ignores VIBE_INCREMENTAL_TELEMETRY_OUT, publishes nothing, and destroys
# nothing -- which is exactly the compiler a destruction-only gate would call
# clean. Two assertions below, and the first one is what proves the mutation
# landed rather than the gate erroring for a setup reason:
#
#   1. the POSITIVE row fails ("published no sidecar"), so "refused" cannot be
#      satisfied by "not implemented";
#   2. the refusal rows report "accepted (exit 0)", so that wiring is live and
#      fires against a compiler that does not refuse.
#
# What this does NOT re-run is the other half of each refusal row -- "and the
# file it named survived". Making that fire needs a compiler that implements
# the feature without the guards, which is a build artifact and not something
# a committed test can carry. Those halves were measured against 9674b06 and
# the table is in the gate's own header; the gate reports 10 failures there,
# against 6 here.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LOG="$(mktemp "${TMPDIR:-/tmp}/vibe_telemetry_guard_selftest.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

set +e
TELEMETRY_GUARD_STAGE2=bootstrap/seed/compiler.wasm \
  bash scripts/check_telemetry_sidecar_guards.sh >"$LOG" 2>&1
status=$?
set -e

rc=0
if [ "$status" -eq 0 ]; then
  echo "[telemetry-sidecar-guards-test] FAIL: the gate passed against the seed," >&2
  echo "  a compiler that publishes no sidecar at all. The gate cannot fail." >&2
  rc=1
fi
if ! grep -q 'published no sidecar' "$LOG"; then
  echo "[telemetry-sidecar-guards-test] FAIL: the gate failed, but not on the" >&2
  echo "  positive row -- the mutation did not land where this test claims." >&2
  cat "$LOG" >&2
  rc=1
fi
if ! grep -q 'accepted (exit 0)' "$LOG"; then
  echo "[telemetry-sidecar-guards-test] FAIL: no refusal row reported an" >&2
  echo "  accepted request, so that wiring was never exercised." >&2
  cat "$LOG" >&2
  rc=1
fi

[ "$rc" -eq 0 ] && echo "[telemetry-sidecar-guards-test] ok"
exit "$rc"
