#!/usr/bin/env bash
# RC vs default real-corpus parity — the actual RC cutover gate (#493 C/F).
#
# The synthetic probe (scripts/rc_cutover_readiness.sh) is necessary but far from
# sufficient: it was green while ~59% of the real fixture test corpus trapped
# under RC (derive macros, traits/dict dispatch, iterators, structural eq). This
# script measures the real signal — compile each `*_test.vibe` under the default
# backend and under RC (VIBE_RC=1, FS-compile path, entry __no_entry__), run each
# (_start runs every `test {}` block; a failing assert traps), and report how
# many default-passing tests ALSO pass under RC. RC must not be worse than
# default. The cutover is safe only when this reaches ~100%.
#
#   bash scripts/rc_corpus_parity.sh [glob ...]   # default glob: fixtures/*_test.vibe
set -uo pipefail
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI="${VIBE_CLI_WASM:-$ROOT_DIR/dist/cli/vibe-cli.wasm}"
[ -s "$CLI" ] || { echo "rc-corpus-parity: compiler wasm not found: $CLI (run scripts/build_cli_wasm.sh)" >&2; exit 2; }
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ "$#" -ge 1 ]; then FILES=("$@"); else FILES=(fixtures/*_test.vibe); fi

# compile <rc:0|1> <src> <out>; run _start. echo pass|trap|cfail.
verdict() {
  local rc="$1" src="$2" out="$3" e=""
  [ "$rc" = 1 ] && e="VIBE_RC=1"
  # $out is a fixed per-run path reused across every fixture in the caller's
  # loop -- remove any stale wasm from a prior fixture first, or a compile
  # failure here (which may leave $out untouched) would fall through to `-s
  # "$out"` still finding the PREVIOUS fixture's wasm and running/reporting
  # that instead of catching the compile regression as `cfail`.
  rm -f "$out"
  env $e VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$CLI" "$src" "$out" __no_entry__ >/dev/null 2>&1
  [ -s "$out" ] || { echo cfail; return; }
  if env VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$RUNNER" --invoke _start "$out" >/dev/null 2>&1; then echo pass; else echo trap; fi
}

denom=0; rc_ok=0; worse=""
for src in "${FILES[@]}"; do
  [ -f "$src" ] || continue
  grep -q 'test "' "$src" 2>/dev/null || continue   # only files with test blocks
  d="$(verdict 0 "$src" "$WORK/d.wasm")"
  [ "$d" = pass ] || continue                        # only count default-passing tests
  denom=$((denom + 1))
  r="$(verdict 1 "$src" "$WORK/r.wasm")"
  if [ "$r" = pass ]; then rc_ok=$((rc_ok + 1)); else worse="$worse $(basename "$src" .vibe):$r"; fi
done

echo "default-passing tests: $denom | RC also pass: $rc_ok | RC worse: $((denom - rc_ok))"
if [ "$denom" -gt 0 ]; then echo "RC pass rate: $(( rc_ok * 100 / denom ))%"; fi
[ -n "$worse" ] && { echo "RC-worse:"; printf '%s\n' $worse; }
[ "$rc_ok" -eq "$denom" ] && { echo "rc-corpus-parity: PARITY — RC matches default on this corpus"; exit 0; }
echo "rc-corpus-parity: NOT AT PARITY — RC is worse than default on $((denom - rc_ok)) test(s); cutover unsafe"
exit 1
