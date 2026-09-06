#!/usr/bin/env bash
# Self-test for scripts/check_compile_only_lanes.sh (#2248 rule: a gate must
# prove it can fail). Each case mutates a REAL input and asserts the gate fails
# with the message for that mutation; the control run must pass.
#
#   1. blind      -- the named artifact with its name section stripped: the
#                    scan must refuse to certify what it cannot see.
#   2. leak       -- a named wasm that defines a function of a dropped lane
#                    (a probe program spelling `compile_file_fs_mode_gc`):
#                    the absence check must name it.
#   3. accepted   -- the full CLI stage2, invoked as `cli_main`: it serves
#                    VIBE_BACKEND=gc, so the refusal check must fail.
#   4. control    -- the real compile-only artifact passes.
#
# Fixture: the named compile-only artifact the gate builds
# (_build/compile_only/vibe_compile_only.names.wasm); built here when absent.
# In release-check this task depends on check-compile-only-lanes, so the gate
# has finished writing it before this reads it; the gate's own scratch is a
# private mktemp directory, so the two never share a path even when run side
# by side. COMPILE_ONLY_STAGE2 overrides the compiler, as for the gate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"
GATE="scripts/check_compile_only_lanes.sh"
STAGE2="$(resolve_stage2 compile-only-lanes-test "${COMPILE_ONLY_STAGE2:-}")" || exit 1
ART="$ROOT_DIR/_build/compile_only/vibe_compile_only.names.wasm"
if [ ! -s "$ART" ]; then
  bash scripts/build_compile_only.sh --names --out "$ART" --compiler "$STAGE2" >&2
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/compile_only_lanes_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

expect_fail() { # <case> <needle> <gate args...>
  local label="$1" needle="$2"; shift 2
  local log="$TMP/$label.log" rc=0
  bash "$GATE" "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "check_compile_only_lanes_test: FAIL ($label): the gate passed on a mutated input" >&2
    cat "$log" >&2
    exit 1
  fi
  if ! grep -qF -- "$needle" "$log"; then
    echo "check_compile_only_lanes_test: FAIL ($label): the gate failed, but not with '$needle':" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "check_compile_only_lanes_test: ok ($label): failed as expected"
}

# 1. blind: drop the "name" custom section. The mutation must have hit -- a
# copy identical to the artifact proves nothing.
STRIPPED="$TMP/stripped.wasm"
python3 - "$ART" "$STRIPPED" <<'PY'
import sys
src, dst = sys.argv[1:]
b = open(src, "rb").read()
def uleb(p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7f) << s; s += 7
        if not x & 0x80:
            return r, p
out = bytearray(b[:8]); p = 8; dropped = 0
while p < len(b):
    sid = b[p]; size, q = uleb(p + 1); end = q + size
    if sid == 0:
        nlen, r = uleb(q)
        if b[r:r + nlen] == b"name":
            dropped += 1; p = end; continue
    out += b[p:end]; p = end
assert dropped == 1, dropped
open(dst, "wb").write(out)
PY
cmp -s "$ART" "$STRIPPED" && { echo "check_compile_only_lanes_test: FAIL (blind): strip did not change the artifact" >&2; exit 1; }
expect_fail blind "names only" --scan-only "$STRIPPED"

# 2. leak: a named user build whose function names include a dropped lane's.
# Enough functions that the runtime's unnamed helpers stay under the 10% the
# scan tolerates; the mutation is verified by reading the names back first.
LEAK_SRC="$TMP/leak.vibe"
{
  echo 'fn compile_file_fs_mode_gc() -> Int { 1 }'
  i=0
  while [ "$i" -lt 60 ]; do
    echo "fn helper_$i(x: Int) -> Int { x + $i }"
    i=$((i + 1))
  done
  printf 'fn main() -> Int {\n  let mut acc = compile_file_fs_mode_gc()\n'
  i=0
  while [ "$i" -lt 60 ]; do
    echo "  acc = helper_$i(acc)"
    i=$((i + 1))
  done
  printf '  acc\n}\n'
} > "$LEAK_SRC"
LEAK="$TMP/leak.wasm"
env $(sed -n '/^VIBE_SELECTOR_ORDER="/,/"$/p' "$ROOT_DIR/runtime/vibe" | tr -d '"' | sed 's/^VIBE_SELECTOR_ORDER=//' | sed 's/\(VIBE_[A-Z_]*\)/-u \1/g') \
  -u VIBE_RC VIBE_WASM_NAMES=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" "$LEAK_SRC" "$LEAK" main >"$TMP/leak.build.log" 2>&1 || true
[ -s "$LEAK" ] || { echo "check_compile_only_lanes_test: FAIL (leak): probe did not compile" >&2; cat "$LEAK.diag" 2>/dev/null >&2; exit 1; }
node scripts/wasm_func_sizes.mjs "$LEAK" --top 1000000 | grep -q 'compile_file_fs_mode_gc' \
  || { echo "check_compile_only_lanes_test: FAIL (leak): the probe's name section lacks compile_file_fs_mode_gc, so the mutation did not hit" >&2; exit 1; }
expect_fail leak "still defines functions of a dropped lane" --scan-only "$LEAK"

# 3. accepted: the full CLI serves the gc lane, so the refusal check fails on
# the first switch.
expect_fail accepted "VIBE_BACKEND=gc was ACCEPTED" --artifact "$STAGE2" --entry cli_main

# 4. control.
if ! bash "$GATE" --artifact "$ART" --entry cli_main_compile_only >"$TMP/control.log" 2>&1; then
  echo "check_compile_only_lanes_test: FAIL (control): the gate rejects the real compile-only artifact" >&2
  cat "$TMP/control.log" >&2
  exit 1
fi
echo "check_compile_only_lanes_test: ok (control)"
echo "check_compile_only_lanes_test: all cases ok"
