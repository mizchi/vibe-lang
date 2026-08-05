#!/usr/bin/env bash
# Regenerate fixtures/async_lift_run42.component.wasm — a self-contained async
# component (its async-lifted `run()` returns 42) emitted by the selfhost async
# codegen (comp_emit_component_wasm_async_trampolined_p1, docs/spec/wasi-p3-async.md
# §3.1). The selfhost-only gate (step 24) runs it on wasmtime with the async
# flags to prove the async runtime path EXECUTES.
#
# Not run in CI: compiling a driver that imports the deep compiler module graph
# via FS-compile is stack-fragile on a cold cache, so the emitted component is
# committed instead. Run this manually after changing the async component codegen
# (the byte-level component_codegen_test will flag such changes).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# `|| true`: no generations dir => ls exits nonzero => pipefail would abort
# here, skipping the explanatory message below.
STAGE2="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
[ -s "$STAGE2" ] || { echo "no stage2 — run: bash scripts/generations.sh build" >&2; exit 1; }
WORK="_build/_emit_async_fixture"; mkdir -p "$WORK"
cat > "$WORK/emit.vibe" <<'EOF'
import ../../lib/@vibe/compiler/bytebuf.vibe { bytebuf_new, bytebuf_push, bytebuf_push_section, bytebuf_push_vec_header, bytebuf_to_bytes }
import ../../lib/@vibe/compiler/component_codegen.vibe { comp_emit_component_wasm_async_trampolined_p1 }
import ../../lib/@vibe/compiler/wasm_emit.vibe { emit_header, emit_func_type_raw, emit_function_section, emit_export_section, emit_i64_const, emit_code_section, emit_name }
let build_core = () -> Bytes {
  let out = bytebuf_new()
  emit_header(out)
  let tc = bytebuf_new()
  bytebuf_push_vec_header(tc, 2)
  emit_func_type_raw(tc, [127, 127, 127, 127], [127])
  emit_func_type_raw(tc, [126], [126])
  bytebuf_push_section(out, 1, tc)
  let ic = bytebuf_new()
  bytebuf_push_vec_header(ic, 1)
  emit_name(ic, "wasi_snapshot_preview1")
  emit_name(ic, "fd_write")
  bytebuf_push(ic, 0)
  bytebuf_push(ic, 0)
  bytebuf_push_section(out, 2, ic)
  emit_function_section(out, [1])
  emit_export_section(out, "run", 1)
  let body = bytebuf_new()
  emit_i64_const(body, 42)
  emit_code_section(out, [body])
  bytebuf_to_bytes(out)
}
export let main = () -> Int with Fs {
  let comp = comp_emit_component_wasm_async_trampolined_p1(build_core(), "run", 120)
  Fs::write_bytes("fixtures/async_lift_run42.component.wasm", comp)
  Bytes::length(comp)
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  "$WORK/emit.vibe" "$WORK/emit.wasm" main >/dev/null 2>&1
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$WORK/emit.wasm" >/dev/null 2>&1
rm -rf "$WORK"
echo "wrote fixtures/async_lift_run42.component.wasm ($(wc -c < fixtures/async_lift_run42.component.wasm) bytes)"
