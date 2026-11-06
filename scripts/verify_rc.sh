#!/usr/bin/env bash
# RC self-hosting verification (#705): build the compiler ITSELF on the
# Perceus RC backend and require it to reproduce the bump-built compiler's
# output byte-for-byte.
#
#   bash scripts/verify_rc.sh [stage2.wasm]      (or: pkf run verify-rc-selfhost)
#
# Steps: (1) CLI compiles the flat bundle with VIBE_RC=0 -> REF and
# VIBE_RC=1 -> RCSTAGE; (2) RCSTAGE (running on the RC runtime) compiles the
# bundle with VIBE_RC=0; (3) the result must equal REF. Historically this
# failed via the env_cache MapBuilder heap corruption (#723) and the raw-ABI
# host-import tag boundary (untagged ints vs RC's n<<1 — args-get fetched the
# wrong argv slot, stat_token/args_len results were misread as tagged).
#
# Each step compiles the whole flat bundle (~15 MB), which overflows the host
# runner's default 4 MB node stack while type-checking. The bootstrap build
# compiles the same input with a 128 MB one, so this does too, through the
# same knob (#3874). A failing step prints the tail of its own output: "no
# output" alone hid that stack overflow for weeks.
set -uo pipefail
# node's --stack-size must fit in the OS stack, or the deep recursion it allows
# segfaults instead (measured: 128 MB under the default `ulimit -s 8192`
# killed generate_bundle.sh). Raise the soft limit to the hard one.
ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -H -s)" 2>/dev/null || true
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. scripts/resolve_stage2.sh
CLI="${1:-$(resolve_stage2_generation rc-selfhost "$PWD")}"
[ -s "$CLI" ] || { echo "[rc-selfhost] no stage2 CLI (build one first)" >&2; exit 2; }
# The bundle is generated, not tracked: bring it up to date with the sources
# (a ~1 s no-op when it already is), or the check measures yesterday's compiler.
bash scripts/ensure_generated.sh >/dev/null || { echo "[rc-selfhost] FAIL: ensure_generated.sh" >&2; exit 1; }
BUNDLE=lib/@vibe/compiler/_cli_adapter_module_source.vibe
OUT=_build/rc_selfhost
mkdir -p "$OUT"
RUN="bash scripts/run_wasm_vibe_host_runner.sh"
NODE_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=${VIBE_GENERATION_NODE_STACK_SIZE:-131072}}"
ENVV=(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_NODE_WASM_FLAGS="$NODE_FLAGS")

# <name> <log>: report a step that left no output, with what it said.
step_failed() {
  echo "[rc-selfhost] FAIL: $1 produced no output; last lines of its log ($2):" >&2
  tail -n 15 "$2" >&2
  [ -s "$OUT/$1.wasm.diag" ] && { echo "[rc-selfhost] $1.wasm.diag:" >&2; head -n 5 "$OUT/$1.wasm.diag" >&2; }
  exit 1
}

echo "[rc-selfhost] cli=$CLI"
rm -f "$OUT"/ref.wasm* "$OUT"/rcstage.wasm* "$OUT"/rcout.wasm* "$OUT"/*.log
env "${ENVV[@]}" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=0 $RUN --invoke cli_main "$CLI" "$BUNDLE" "$OUT/ref.wasm" cli_main >"$OUT/ref.log" 2>&1
[ -s "$OUT/ref.wasm" ] || step_failed ref "$OUT/ref.log"
env "${ENVV[@]}" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=1 $RUN --invoke cli_main "$CLI" "$BUNDLE" "$OUT/rcstage.wasm" cli_main >"$OUT/rcstage.log" 2>&1
[ -s "$OUT/rcstage.wasm" ] || step_failed rcstage "$OUT/rcstage.log"
run_bounded 600 env "${ENVV[@]}" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=0 $RUN --invoke cli_main "$OUT/rcstage.wasm" "$BUNDLE" "$OUT/rcout.wasm" cli_main >"$OUT/rcout.log" 2>&1
if [ -s "$OUT/rcout.wasm" ] && cmp -s "$OUT/rcout.wasm" "$OUT/ref.wasm"; then
  echo "[rc-selfhost] OK: RC-built compiler output is byte-identical ($(wc -c <"$OUT/rcout.wasm") bytes)"
  exit 0
fi
[ -s "$OUT/rcout.wasm" ] || step_failed rcout "$OUT/rcout.log"
echo "[rc-selfhost] FAIL: the RC-built compiler's output differs from the reference ($(wc -c <"$OUT/rcout.wasm") vs $(wc -c <"$OUT/ref.wasm") bytes)" >&2
exit 1
