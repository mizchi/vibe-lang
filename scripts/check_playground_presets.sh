#!/usr/bin/env bash
# Type-check the vibe source of every playground preset.
#
# playground/src/main.ts embeds its starter programs as TypeScript template
# literals, so they are vibe source that no vibe tool ever sees. That cost was
# measured: when #1429 removed the braced effect row and #1461 retired `Error`
# as a row spelling, two presets kept BOTH dead spellings (`with { Error }`) and
# stayed broken until someone opened the page (#1497). The presets are the first
# thing a visitor runs, so they are the worst place to leave rot.
#
# Scope is a TYPE CHECK, not a build. The page compiles with the wasm-gc
# backend (`BUILD_TARGET = "src/lib wasm-gc"` in main.ts) through a
# browser-hosted compiler this script has no way to drive; type checking is
# backend-independent and catches the failure mode that actually happened here
# (syntax and type rot), so that is what this gate asserts.
#
# Environment:
#   PLAYGROUND_STAGE2  compiler wasm to use. Default: newest
#                      _build/selfhost/generations/*/stage2.wasm. The committed
#                      seed is NOT a fallback -- it is the previous bootstrap
#                      tag and still accepts syntax the current compiler has
#                      removed, so a seed-driven run reports green on rotted
#                      presets, which is the blind spot this closes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SRC="playground/src/main.ts"
[ -f "$SRC" ] || { echo "[playground-presets] no such file: $SRC" >&2; exit 2; }

stage2="${PLAYGROUND_STAGE2:-}"
if [ -z "$stage2" ]; then
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    if [ -s "${gen}stage2.wasm" ]; then stage2="${gen}stage2.wasm"; break; fi
  done
fi
if [ -z "$stage2" ] || [ ! -s "$stage2" ]; then
  echo "[playground-presets] no stage2 found." >&2
  echo "[playground-presets] build one (bash scripts/compiler_gate.sh) or set PLAYGROUND_STAGE2." >&2
  echo "[playground-presets] the committed seed is deliberately not a fallback -- it accepts" >&2
  echo "[playground-presets] syntax the current compiler has removed and would report green." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MANIFEST="$WORK/manifest"

# Extract each `{ id: "..", source: `..` }` entry of PRESETS into its own .vibe
# file and write a (path, id) manifest.
python3 scripts/extract_playground_presets.py "$SRC" "$WORK" > "$MANIFEST"

export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
bash scripts/install.sh --cli-wasm "$(cd "$(dirname "$stage2")" && pwd)/$(basename "$stage2")" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "[playground-presets] install failed: no launcher at $VIBE" >&2; exit 2; }

echo "[playground-presets] compiler = $stage2"

fail=0
count=0
while IFS=$'\t' read -r path pid; do
  [ -n "$path" ] || continue
  count=$((count + 1))
  # #1567 slice 2: judge by EXIT STATUS, not by matching an `ok:` line. A clean
  # check is now silent (empty output + exit 0), so pattern-matching the output
  # would report every clean preset as broken -- with an empty reason, since
  # there is no diagnostic to print.
  if out="$("$VIBE" check "$path" 2>&1)"; then :; else
    fail=$((fail + 1))
    echo "[playground-presets] FAIL: preset '$pid' ($SRC)" >&2
    printf '%s\n' "$out" | head -3 | sed 's/^/                      /' >&2
  fi
done < "$MANIFEST"

if [ "$fail" -gt 0 ]; then
  echo "[playground-presets] $fail of $count preset(s) do not type-check." >&2
  echo "[playground-presets] fix them in $SRC -- they are the first vibe a visitor runs." >&2
  exit 1
fi
echo "[playground-presets] ok: $count preset(s)"
