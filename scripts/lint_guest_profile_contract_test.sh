#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_guest_profile_lint.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/runtime/viberun/src" "$TMP_ROOT/docs/spec"
cp "$ROOT/runtime/viberun/src/main.rs" "$TMP_ROOT/runtime/viberun/src/main.rs"
cp "$ROOT/runtime/vibe" "$TMP_ROOT/runtime/vibe"
cp "$ROOT/docs/spec/profiling.md" "$TMP_ROOT/docs/spec/profiling.md"

VIBE_GUEST_PROFILE_LINT_ROOT="$TMP_ROOT" bash "$ROOT/scripts/lint_guest_profile_contract.sh" >/dev/null

sed 's/struct GuestCpuClock/struct RemovedGuestCpuClock/' \
  "$ROOT/runtime/viberun/src/main.rs" > "$TMP_ROOT/runtime/viberun/src/main.rs"
if VIBE_GUEST_PROFILE_LINT_ROOT="$TMP_ROOT" \
  bash "$ROOT/scripts/lint_guest_profile_contract.sh" >"$TMP_ROOT/out" 2>&1; then
  echo "guest-profile contract self-test: missing clock unexpectedly passed" >&2
  exit 1
fi
grep -q 'missing shared GuestCpuClock' "$TMP_ROOT/out" \
  || { echo "guest-profile contract self-test: missing diagnostic" >&2; exit 1; }

echo "guest-profile contract self-test: ok"
