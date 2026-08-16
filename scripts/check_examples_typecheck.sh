#!/usr/bin/env bash
# Type-check every examples/*.vibe against a stage2 built for THIS checkout.
#
# examples/ is the repo's user-facing sample surface and had NOTHING checking
# it. That cost was measured, not hypothetical: when #1429 removed the braced
# effect row and #1461 retired `Error` as a row spelling, six example files kept
# the dead syntax and stayed broken until the seed bump moved the seed past the
# removal (#1497). Two more files (`syntax.vibe`, `trait_map_set.vibe`) had
# ordinary type errors that predated all of that and had simply never been run.
#
# `scripts/pkfire/examples_smoke.sh` is NOT this: it compiles four hand-picked
# files through `_build/dist/selfhost_compiler.wasm`, a path the current build
# layout no longer produces, and no workflow invokes it.
#
# Known failures live in scripts/examples_typecheck_known_failures.txt as a
# RATCHET (same shape as scripts/vibe_fmt_allowlist.txt): a listed file may
# fail, an unlisted file may not, and a listed file that starts PASSING is also
# an error so the list cannot rot. Every known failure is printed on every run
# -- the point is that they stay visible, unlike the silence that let the rot
# above accumulate.
#
# Environment:
#   EXAMPLES_STAGE2  compiler wasm to use. Default: newest
#                    _build/selfhost/generations/*/stage2.wasm. The committed
#                    seed is NOT a fallback: it is the previous bootstrap tag
#                    and still accepts syntax the current compiler rejects, so
#                    a seed-driven run reports green on rotted examples --
#                    exactly the failure mode this script exists to close.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

KNOWN_FAILURES="scripts/examples_typecheck_known_failures.txt"

stage2="${EXAMPLES_STAGE2:-}"
if [ -z "$stage2" ]; then
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    if [ -s "${gen}stage2.wasm" ]; then
      stage2="${gen}stage2.wasm"
      break
    fi
  done
fi
if [ -z "$stage2" ] || [ ! -s "$stage2" ]; then
  echo "[examples-typecheck] no stage2 found." >&2
  echo "[examples-typecheck] build one (bash scripts/compiler_gate.sh) or set EXAMPLES_STAGE2." >&2
  echo "[examples-typecheck] the committed seed is deliberately not a fallback -- it accepts" >&2
  echo "[examples-typecheck] syntax the current compiler has removed and would report green." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export VIBE_HOME="$WORK/home"
export VIBE_BIN_DIR="$WORK/bin"
bash install/install.sh --cli-wasm "$(cd "$(dirname "$stage2")" && pwd)/$(basename "$stage2")" >/dev/null 2>&1
VIBE="$VIBE_BIN_DIR/vibe"
[ -x "$VIBE" ] || { echo "[examples-typecheck] install failed: no launcher at $VIBE" >&2; exit 2; }

echo "[examples-typecheck] compiler = $stage2"

is_known() {
  [ -f "$KNOWN_FAILURES" ] || return 1
  grep -vE '^\s*(#|$)' "$KNOWN_FAILURES" | grep -qxF "$1"
}

new_failures=()
fixed_known=()
checked=0
known_hit=0

for f in examples/*.vibe; do
  checked=$((checked + 1))
  # #1567 slice 2: judge by EXIT STATUS, not by matching an `ok:` line. A clean
  # check is now silent (empty output + exit 0), so pattern-matching the output
  # would report every clean example as a failure.
  if out="$("$VIBE" check "$f" 2>&1)"; then ok=1; else ok=0; fi
  if [ "$ok" -eq 1 ]; then
    if is_known "$f"; then
      fixed_known+=("$f")
    fi
  else
    first="$(printf '%s\n' "$out" | head -1)"
    if is_known "$f"; then
      known_hit=$((known_hit + 1))
      echo "[examples-typecheck] known failure: $f"
      echo "                     $first"
    else
      new_failures+=("$f")
      echo "[examples-typecheck] FAIL: $f" >&2
      echo "                     $first" >&2
    fi
  fi
done

rc=0
if [ "${#new_failures[@]}" -gt 0 ]; then
  echo "[examples-typecheck] ${#new_failures[@]} example(s) do not type-check and are not in $KNOWN_FAILURES." >&2
  echo "[examples-typecheck] fix the example, or add it there with the issue that tracks it." >&2
  rc=1
fi
if [ "${#fixed_known[@]}" -gt 0 ]; then
  echo "[examples-typecheck] these are listed as known failures but now PASS -- remove them from $KNOWN_FAILURES:" >&2
  for f in "${fixed_known[@]}"; do echo "                     $f" >&2; done
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "[examples-typecheck] ok: $checked example(s), $known_hit known failure(s), 0 new"
fi
exit "$rc"
