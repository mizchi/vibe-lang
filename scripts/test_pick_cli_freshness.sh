#!/usr/bin/env bash
# pick_cli's AOT-image freshness guard (Codex review of #2858).
#
# runtime/vibe prefers lib/vibe-cli.cwasm, a wasmtime AOT image that only the
# runner it was precompiled by can load: viberun deserializes it unsafely, and
# an image from a different wasmtime build is undefined behaviour. So the
# launcher may use it only when NOTHING it depends on is newer -- neither the
# runner nor the portable wasm it was precompiled from. The guard once went
# missing and a stale image was chosen because it existed; this gate keeps it.
#
# It builds a fake installed toolchain (the layout is all pick_cli reads; no
# wasm is ever executed -- `vibe version` prints the choice) and asserts:
#   * image newer than runner and wasm     -> the .cwasm is chosen
#   * image as old as the wasm (equal)     -> the .cwasm is chosen
#   * wasm refreshed after the image       -> the portable .wasm is chosen
#   * runner replaced after the image      -> the portable .wasm is chosen
#   * no image at all                      -> the portable .wasm is chosen
#   * VIBE_CLI_WASM set                    -> that file, however fresh the image
#
# VIBE_PICK_CLI_LAUNCHER names another launcher to test (the self-test does).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${VIBE_PICK_CLI_LAUNCHER:-$ROOT/runtime/vibe}"
[ -f "$LAUNCHER" ] || { echo "[pick-cli-freshness] FAIL: launcher not found: $LAUNCHER" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-pick-cli.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[pick-cli-freshness] FAIL: $*" >&2; exit 1; }

tc="$WORK/home/toolchains/dev"
mkdir -p "$tc/bin" "$tc/lib"
cp "$LAUNCHER" "$tc/bin/vibe"; chmod +x "$tc/bin/vibe"
printf '#!/bin/sh\nexit 0\n' > "$tc/bin/viberun"; chmod +x "$tc/bin/viberun"
printf 'not a wasm\n' > "$tc/lib/vibe-cli.wasm"
printf 'not a cwasm\n' > "$tc/lib/vibe-cli.cwasm"
runner="$tc/bin/viberun"; wasm="$tc/lib/vibe-cli.wasm"; cwasm="$tc/lib/vibe-cli.cwasm"

# The selectors the launcher honours over its own toolchain are cleared so an
# inherited VIBE_CLI_WASM (the dev container exports one) cannot answer for
# pick_cli. Each case names the timestamps it needs explicitly.
picked() {
  ( cd "$WORK" && env -u VIBE_CLI_WASM -u VIBE_CLI_CWASM -u VIBE_RUNNER -u VIBE_TOOLCHAIN \
      VIBE_HOME="$WORK/home" "$tc/bin/vibe" version 2>/dev/null ) | sed -n 's/^compiler:  *//p'
}
expect() {
  local want="$1" why="$2" got
  got="$(picked)"
  [ "$got" = "$want" ] || fail "$why: expected $want, got ${got:-<nothing>}"
}

# 1. image newer than both dependencies -> the image.
touch -t 202001010000 "$runner"; touch -t 202001010100 "$wasm"; touch -t 202001010200 "$cwasm"
expect "$cwasm" "a fresh .cwasm (newer than runner and wasm) must be chosen"

# 2. image and wasm share an mtime (precompiled in the same second) -> the image.
touch -t 202001010200 "$wasm"
expect "$cwasm" "an equal-mtime .cwasm (built right after the wasm) must be chosen"

# 3. the wasm was refreshed after the image -> the portable wasm.
touch -t 202001010300 "$wasm"
expect "$wasm" "a wasm newer than the .cwasm makes the image stale: the .wasm must be chosen"

# 4. the runner was replaced after the image -> the portable wasm.
touch -t 202001010100 "$wasm"; touch -t 202001010300 "$runner"
expect "$wasm" "a runner newer than the .cwasm makes the image UB: the .wasm must be chosen"

# 5. no image -> the portable wasm.
touch -t 202001010000 "$runner"; rm -f "$cwasm"
expect "$wasm" "with no .cwasm the .wasm must be chosen"

# 6. an explicit VIBE_CLI_WASM wins over a fresh image.
printf 'not a cwasm\n' > "$cwasm"; touch -t 202001010200 "$cwasm"
printf 'not a wasm either\n' > "$WORK/explicit.wasm"
got="$( cd "$WORK" && env -u VIBE_CLI_CWASM -u VIBE_RUNNER -u VIBE_TOOLCHAIN VIBE_HOME="$WORK/home" \
        VIBE_CLI_WASM="$WORK/explicit.wasm" "$tc/bin/vibe" version 2>/dev/null | sed -n 's/^compiler:  *//p' )"
[ "$got" = "$WORK/explicit.wasm" ] || fail "VIBE_CLI_WASM must win over the toolchain's .cwasm: got ${got:-<nothing>}"

echo "[pick-cli-freshness] ok (6 cases: the .cwasm is used only when neither the runner nor the wasm is newer)"
