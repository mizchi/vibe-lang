#!/usr/bin/env bash
set -euo pipefail

ROOT="${VIBE_POLICY_RAW_FS_ROOT:-}"
WRITE_ROOT="${VIBE_POLICY_RAW_FS_WRITE_ROOT:-}"
BASE_RUNNER="${VIBE_POLICY_BASE_RUNNER:-}"
EXPECTED_ROOT="/workspace/repo"
EXPECTED_GENERATION_WRITE_ROOT="/workspace/repo/_build"
EXPECTED_MEASUREMENT_WRITE_ROOT="/workspace/repo/_build/selfcompile-policy"
EXPECTED_RUNNER="/opt/policy/scripts/run_wasm_vibe_host_runner_base.sh"

[ "$ROOT" = "$EXPECTED_ROOT" ] || {
  echo "policy runner: VIBE_POLICY_RAW_FS_ROOT must be $EXPECTED_ROOT" >&2
  exit 125
}
case "$WRITE_ROOT" in
  "$EXPECTED_GENERATION_WRITE_ROOT"|"$EXPECTED_MEASUREMENT_WRITE_ROOT") ;;
  *)
    echo "policy runner: invalid phase write authority" >&2
    exit 125
    ;;
esac
[ "$BASE_RUNNER" = "$EXPECTED_RUNNER" ] || {
  echo "policy runner: immutable base runner mismatch" >&2
  exit 125
}
[ -f "$BASE_RUNNER" ] && [ ! -L "$BASE_RUNNER" ] || {
  echo "policy runner: immutable base runner missing or redirected" >&2
  exit 125
}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || {
  echo "policy runner: policy root missing or redirected" >&2
  exit 125
}
[ -d "$WRITE_ROOT" ] && [ ! -L "$WRITE_ROOT" ] || {
  echo "policy runner: phase write root missing or redirected" >&2
  exit 125
}
cd "$ROOT"

exec bash "$BASE_RUNNER" \
  --policy-stat-token content-v1 \
  --policy-stat-root "$ROOT" \
  --policy-raw-fs-root "$ROOT" \
  --policy-raw-fs-write-root "$WRITE_ROOT" \
  "$@"
