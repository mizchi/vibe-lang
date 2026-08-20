#!/usr/bin/env bash
# #2134, enforced: a VALID module must not stop compiling because of how many
# top-level declarations it has.
#
# The ceiling was never a compiler limit -- it is the HOST's JS stack. The
# checker recurses once per top-level statement, so node's default ~1 MB stack
# capped a module at ~1300 declarations (1200 ok, 1400 fail, 3/3 each way).
# The SIZE of a declaration is irrelevant; the bodies below are `x + i`. The
# relationship is linear in the stack: `--stack-size=4000`, which
# scripts/run_wasm_vibe_host_runner.sh now derives from `ulimit -s`, moves the
# same ceiling to ~5000.
#
# EVERY RUN GENERATES UNIQUE CONTENT, and that is load-bearing. A successful
# compile writes a persistent `_build/vibe_selfhost_module_header_v2_*` row
# keyed by source content, and afterwards that exact source compiles on the
# default stack. A fixed corpus would therefore pass forever after its own
# first green run -- including with the fix reverted. That effect is what made
# three different ceilings get published in #2134 before it was spotted.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Above the default-stack ceiling (~1300) and below the raised one (~5000), so
# the gate discriminates in both directions with headroom on each side.
N="${DECL_SCALE_N:-3000}"
# Same resolution as scripts/check_source_range_contract.sh: newest generation,
# else the committed seed. An explicitly named path that does not exist is an
# ERROR -- never a silent fallback to a different compiler.
STAGE2="${DECL_SCALE_STAGE2:-}"
if [ -n "$STAGE2" ]; then
  if [ ! -f "$STAGE2" ]; then
    echo "declaration-scale: DECL_SCALE_STAGE2=$STAGE2 does not exist" >&2
    exit 1
  fi
else
  STAGE2="$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
  [ -n "$STAGE2" ] || STAGE2="bootstrap/seed/compiler.wasm"
  if [ ! -f "$STAGE2" ]; then
    echo "declaration-scale: no compiler found; set DECL_SCALE_STAGE2" >&2
    exit 1
  fi
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_declscale.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DIAG=""

compiles() { # compiles <unique-tag> -> 0 when it produced a module
  local tag="$1" src="$WORK/$1.vibe" out="$WORK/$1.wasm"
  python3 -c "
import sys
n, t = int(sys.argv[1]), sys.argv[2]
for i in range(n):
    print(f'fn {t}_f{i}(x: Int) -> Int {{ x + {i} }}')
print(f'fn main() -> Unit {{ let _ = {t}_f0(1) }}')
" "$N" "$tag" > "$src"
  env VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$src" "$out" __no_entry__ >/dev/null 2>&1 || true
  DIAG="$(head -1 "$out.diag" 2>/dev/null || true)"
  [ -s "$out" ]
}

# Green: with the raise, N declarations compile from cold.
if ! compiles "green_$$"; then
  echo "declaration-scale: FAIL: a valid module of $N top-level declarations did not compile" >&2
  echo "  $DIAG" >&2
  echo "  This is #2134: the checker recurses per top-level statement and the HOST stack" >&2
  echo "  runs out. scripts/run_wasm_vibe_host_runner.sh raises it via VIBE_NODE_STACK_SIZE" >&2
  echo "  (bounded by ulimit -s); check that hunk first." >&2
  exit 1
fi

# Red: the same size must still fail without the raise, on content that has
# likewise never compiled -- otherwise the Green case above proves nothing.
if VIBE_NODE_STACK_SIZE=0 compiles "red_$$"; then
  echo "declaration-scale: FAIL: $N declarations compile even with VIBE_NODE_STACK_SIZE=0," >&2
  echo "  so this gate no longer proves the raise is doing anything. Raise DECL_SCALE_N" >&2
  echo "  above the current default-stack ceiling (#2134)." >&2
  exit 1
fi

# A caller that names its own --stack-size must keep it. node takes the LAST
# flag (measured), so an unconditional append would override it -- and
# scripts/generations.sh passes --stack-size=131072 for the bootstrap compiles,
# where silently dropping to 4 MB removes a 32x margin in the most load-bearing
# place there is.
#
# Asserted end to end, not by re-reading the script: with a caller-set stack
# far BELOW node's default, a module that compiles by default must now fail. If
# our raise were still appended after it, this would pass and prove nothing.
if VIBE_NODE_WASM_FLAGS="--stack-size=500" compiles "caller_$$"; then
  echo "declaration-scale: FAIL: a caller-set --stack-size=500 did not take effect," >&2
  echo "  so run_wasm_vibe_host_runner.sh is appending its own after the caller's." >&2
  echo "  node takes the LAST --stack-size, so that OVERRIDES generations.sh's" >&2
  echo "  --stack-size=131072 and cuts the bootstrap stack to 4 MB (#2134)." >&2
  exit 1
fi

echo "declaration-scale: ok ($N top-level declarations compile; still fail without the stack raise)"
