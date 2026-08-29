#!/usr/bin/env bash
# RC self-hosting verification (#705): build the compiler ITSELF on the
# Perceus RC backend and require it to reproduce the bump-built compiler's
# output byte-for-byte.
#
#   bash scripts/verify_rc.sh [stage2.wasm]
#
# Steps: (1) CLI compiles the committed bundle with VIBE_RC=0 -> REF and
# VIBE_RC=1 -> RCSTAGE; (2) RCSTAGE (running on the RC runtime) compiles the
# bundle with VIBE_RC=0; (3) the result must equal REF. Historically this
# failed via the env_cache MapBuilder heap corruption (#723) and the raw-ABI
# host-import tag boundary (untagged ints vs RC's n<<1 — args-get fetched the
# wrong argv slot, stat_token/args_len results were misread as tagged).
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI="${1:-$(ls -t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1)}"
[ -s "$CLI" ] || { echo "[rc-selfhost] no stage2 CLI (build one first)" >&2; exit 2; }
BUNDLE=lib/@vibe/compiler/_cli_adapter_module_source.vibe
OUT=_build/rc_selfhost
mkdir -p "$OUT"
RUN="bash scripts/run_wasm_vibe_host_runner.sh"
ENVV=(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw)

echo "[rc-selfhost] cli=$CLI"
rm -f "$OUT"/ref.wasm* "$OUT"/rcstage.wasm* "$OUT"/rcout.wasm*
env "${ENVV[@]}" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=0 $RUN --invoke cli_main "$CLI" "$BUNDLE" "$OUT/ref.wasm" cli_main >/dev/null 2>&1
env "${ENVV[@]}" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=1 $RUN --invoke cli_main "$CLI" "$BUNDLE" "$OUT/rcstage.wasm" cli_main >/dev/null 2>&1
[ -s "$OUT/ref.wasm" ] && [ -s "$OUT/rcstage.wasm" ] || { echo "[rc-selfhost] FAIL: stage build produced no output" >&2; exit 1; }
timeout 600 env "${ENVV[@]}" VIBE_INTERNAL_TRUSTED_SOURCE=1 VIBE_RC=0 $RUN --invoke cli_main "$OUT/rcstage.wasm" "$BUNDLE" "$OUT/rcout.wasm" cli_main >/dev/null 2>&1
if [ -s "$OUT/rcout.wasm" ] && cmp -s "$OUT/rcout.wasm" "$OUT/ref.wasm"; then
  echo "[rc-selfhost] OK: RC-built compiler output is byte-identical ($(wc -c <"$OUT/rcout.wasm") bytes)"
  exit 0
fi
echo "[rc-selfhost] FAIL: $(head -1 "$OUT/rcout.wasm.diag" 2>/dev/null || echo 'no output / byte mismatch')" >&2
exit 1
