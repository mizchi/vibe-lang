#!/usr/bin/env bash
# Red/green for profile_compile.sh's name-section guard (#2248: a check means
# nothing until it is shown it can fail).
#
# Both fixtures are synthesised here as minimal wasm modules rather than taken
# from _build: a test that needs a built generation is a test that gets skipped
# in CI, and then the guard it covers rots (#2252).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "profile-compile-test: $*" >&2; exit 1; }

# A wasm module whose only custom section is the one named by $1.
synth() { # name path
  python3 - "$1" "$2" <<'PY'
import sys
name = sys.argv[1].encode()
payload = bytes([len(name)]) + name
section = bytes([0, len(payload)]) + payload
open(sys.argv[2], "wb").write(b"\0asm\x01\0\0\0" + section)
PY
}
synth vibe.abi "$WORK/stripped.wasm"
synth name "$WORK/named.wasm"
printf 'fn main() -> Int {\n  1\n}\n' > "$WORK/tiny.vibe"

# RED: a stripped artifact is refused, with the rebuild command in the message.
set +e
out="$(bash scripts/profile_compile.sh "$WORK/stripped.wasm" "$WORK/tiny.vibe" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "stripped artifact: expected exit 2, got $rc"
case "$out" in
  *"has no wasm name section"*) ;;
  *) fail "stripped artifact: refusal did not say why: $out" ;;
esac
case "$out" in
  *"VIBE_WASM_NAMES=1"*) ;;
  *) fail "stripped artifact: refusal did not name the fix: $out" ;;
esac
# The refusal must come BEFORE the compile, which is the whole point of it.
case "$out" in
  *wall_ms*) fail "stripped artifact: refused only after running the compile" ;;
  *) ;;
esac

# GREEN: an artifact that HAS a name section gets past the guard. It is not a
# real compiler, so the run fails afterwards -- asserting on the guard's own
# message is what keeps this about the guard.
set +e
out="$(bash scripts/profile_compile.sh "$WORK/named.wasm" "$WORK/tiny.vibe" 2>&1)"
set -e
case "$out" in
  *"has no wasm name section"*) fail "named artifact was refused by the name-section guard: $out" ;;
  *) ;;
esac

echo "profile-compile-test: ok"
