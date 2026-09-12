#!/usr/bin/env bash
# #2669: run the relocation scanner over WHOLE real modules.
#
#   bash scripts/reloc_roundtrip.sh [module.wasm ...]
#
# With no arguments it builds two probe modules -- one per backend -- and adds
# the compiler's own stage2, because the lanes do not exercise the same
# opcodes: the gc backend emits the 0xFB family and the linear one does not.
# That difference is not hypothetical. The scanner passed on stage2 and on a
# 4743-function linear corpus on its first run, and refused `0xfb` by name on
# the first gc-lane module it saw.
#
# WHY THIS IS NOT A `check_*` GATE. It needs built modules, including a
# gc-lane one, so a gate would have to build them in CI for a property whose
# per-shape coverage `reloc_scan_test.vibe` already holds. What this adds is
# the ability to find a shape nobody wrote a synthetic case for, which is a
# thing you do when you TOUCH the decoder, not on every push. Run it then.
# (scripts/prelude_split_memory.sh carries the same shape of note.) Promote it
# once the link step of #2669 gives CI a corpus it already builds.
#
# It still FAILS rather than reporting a clean run when it cannot answer: an
# unknown opcode is refused by the scanner, and a module with zero relocation
# sites is treated as a failure, not as a pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 reloc-roundtrip "${RELOC_ROUNDTRIP_STAGE2:-}")"

targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
  probe_dir="_build/_reloc_probe"
  mkdir -p "$probe_dir"
  cat > "$probe_dir/gcprobe.vibe" <<'PROBE'
struct P { x: Int; y: Int }

fn mk(a: Int) -> P {
  P::{ x: a, y: a + 1 }
}

fn sum(ps: Array[P]) -> Int {
  let mut t = 0
  let mut i = 0
  while i < Array::length(ps) {
    let p = Array::get(ps, i)
    t = t + p.x + p.y
    i = i + 1
  }
  t
}

fn main() -> Int {
  let ps = []
  let mut i = 0
  while i < 8 {
    Array::push(ps, mk(i))
    i = i + 1
  }
  sum(ps)
}
PROBE
  for backend in linear gc; do
    out="$probe_dir/probe_$backend.wasm"
    if [ "$backend" = gc ]; then be=gc; else be=""; fi
    # Delete first, and treat the compiler's exit status as the answer. With
    # neither, a rerun whose compile FAILS leaves the previous run's good wasm
    # in place, `-s` passes, and the oracle scans stale bytes and reports
    # success -- a decoder-coverage check that is green about a module this
    # run never produced. (Codex review on #2702.)
    rm -f "$out"
    build_rc=0
    env -u VIBE_RC ${be:+VIBE_BACKEND=$be} VIBE_WASM_NAMES=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
      VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
      "$probe_dir/gcprobe.vibe" "$out" main >/dev/null 2>&1 || build_rc=$?
    if [ "$build_rc" -ne 0 ] || [ ! -s "$out" ]; then
      echo "reloc-roundtrip: FAIL: could not build the $backend probe module (exit $build_rc)" >&2
      exit 1
    fi
    targets+=("$out")
  done
  targets+=("$STAGE2")
fi

rc=0
for t in "${targets[@]}"; do
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/vibe_run.sh scripts/reloc_roundtrip.vibex -- "$t" 2>&1 \
    | grep -E 'reloc-roundtrip|unknown opcode|unknown 0x|uncaught'; then
    rc=1
  fi
done
if [ "$rc" -ne 0 ]; then
  echo "reloc-roundtrip: FAIL" >&2
  exit 1
fi
echo "reloc-roundtrip: ok"
