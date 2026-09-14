#!/usr/bin/env bash
# Red test for check_telemetry_sidecar_guards.sh (#2248): the gate must be
# able to FAIL, on a real compiler rather than a stub.
#
# Disable telemetry in a copy of the current compiler by replacing its env
# lookup key with an equal-length unused key. Wasm section/data offsets stay
# intact, while a real compiler ignores the request and still builds the input.
# This mutation must not depend on the committed seed lacking the feature:
# bootstrap bumps eventually bring every implemented feature into the seed.
#
# The positive row must report "published no sidecar", and refusal rows must
# report "accepted (exit 0)". Both are required: an unrelated setup failure is
# not evidence that either assertion can catch a broken compiler.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
STAGE2="$(resolve_stage2 telemetry-sidecar-guards-test "${TELEMETRY_GUARD_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
mkdir -p "$ROOT_DIR/_build"
WORK="$(mktemp -d "$ROOT_DIR/_build/telemetry_guard_selftest.XXXXXX")"
LOG="$WORK/gate.log"
MUTANT="$WORK/no-telemetry.wasm"
trap 'rm -rf "$WORK"' EXIT

python3 - "$STAGE2" "$MUTANT" <<'PY_MUTATION'
import pathlib, sys
source, output = map(pathlib.Path, sys.argv[1:])
wasm = source.read_bytes()
old = b"VIBE_INCREMENTAL_TELEMETRY_OUT"
new = b"VIBE_INCREMENTAL_TELEMETRY_OFF"
if old not in wasm or new in wasm:
    raise SystemExit("telemetry-sidecar-guards-test: cannot apply the telemetry key mutation")
assert len(old) == len(new)
output.write_bytes(wasm.replace(old, new))
PY_MUTATION

set +e
env -u VIBE_INCREMENTAL_TELEMETRY_OFF TELEMETRY_GUARD_STAGE2="$MUTANT" \
  bash scripts/check_telemetry_sidecar_guards.sh >"$LOG" 2>&1
status=$?
set -e

rc=0
if [ "$status" -eq 0 ]; then
  echo "[telemetry-sidecar-guards-test] FAIL: the gate passed against the telemetry-disabled compiler," >&2
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
