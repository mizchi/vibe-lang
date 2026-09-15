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

# --- #2738 rows: the clear must be provably able to be a no-op -------------
# The mutation above disables VIBE_INCREMENTAL_TELEMETRY_OUT, which the #2738
# rows do not use. Without a second mutation those rows would be certified by
# nothing -- and "I ran the red case by hand and wrote it in the commit
# message" is the guarantee CLAUDE.md records as evaporating on the next edit.
#
# Same technique, a different key: disable VIBE_INGESTION_TELEMETRY_OUT (28
# bytes, replaced by an equal-length unused key so wasm offsets hold). A
# compiler that ignores the variable never clears the stale sidecar, which is
# exactly the no-op the second half of each #2738 row exists to catch. The
# DIRECTORY half of those rows cannot be red-tested this way -- a compiler that
# ignores the variable also cannot delete the tree -- so it is red-tested
# against the unfixed compiler instead, which is what the issue records.
INGEST_MUTANT="$WORK/no-ingestion.wasm"
python3 - "$STAGE2" "$INGEST_MUTANT" <<'PY_INGEST_MUTATION'
import pathlib, sys
source, output = map(pathlib.Path, sys.argv[1:])
wasm = source.read_bytes()
old = b"VIBE_INGESTION_TELEMETRY_OUT"
new = b"VIBE_INGESTION_TELEMETRY_OFF"
if old not in wasm or new in wasm:
    raise SystemExit("telemetry-sidecar-guards-test: cannot apply the ingestion key mutation")
assert len(old) == len(new)
output.write_bytes(wasm.replace(old, new))
PY_INGEST_MUTATION

set +e
env -u VIBE_INGESTION_TELEMETRY_OFF TELEMETRY_GUARD_STAGE2="$INGEST_MUTANT" \
  bash scripts/check_telemetry_sidecar_guards.sh >"$WORK/ingest.log" 2>&1
ingest_status=$?
set -e

if [ "$ingest_status" -eq 0 ]; then
  echo "[telemetry-sidecar-guards-test] FAIL: the gate passed against a compiler that" >&2
  echo "  never clears VIBE_INGESTION_TELEMETRY_OUT, so the #2738 no-op row cannot fail." >&2
  rc=1
elif ! grep -q 'the clear is a no-op' "$WORK/ingest.log"; then
  echo "[telemetry-sidecar-guards-test] FAIL: the gate failed against the" >&2
  echo "  ingestion-disabled compiler, but not on the #2738 no-op row." >&2
  cat "$WORK/ingest.log" >&2
  rc=1
fi

[ "$rc" -eq 0 ] && echo "[telemetry-sidecar-guards-test] ok"
exit "$rc"
