#!/usr/bin/env bash
# Regenerate fixtures/async_lift_run42.component.wasm — a self-contained async
# component (its async-lifted `run()` returns 42) emitted by the selfhost async
# codegen (comp_emit_component_wasm_async_trampolined_p1, docs/internal/design/wasi-p3-async.md
# §3.1). The selfhost-only gate (step 24) runs it on wasmtime with the async
# flags to prove the async runtime path EXECUTES.
#
#   bash scripts/emit_async_lift_fixture.sh [OUT]   (default: the committed fixture)
#
# Run this after changing the async component codegen (the byte-level
# component_codegen_test will flag such changes). The compiler gate's step 24
# also runs it into _build/ and requires the result to equal the committed
# fixture, so a driver that stops compiling, or a fixture that no longer
# matches the codegen, fails there. The driver imports the
# codegen PACKAGES (@vibe/compiler/codegen/{component,wasm_emit} and
# @vibe/compiler/core), not file paths: the flat paths it used to name moved
# into those packages in #3528 and the script stopped working without anyone
# noticing (#3873).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# The checkout's compiler: the fixture is committed, so it must come from the
# codegen in this tree, not from whichever generation was built last (#3866).
# EMIT_ASYNC_FIXTURE_STAGE2 names it explicitly (the compiler gate passes the
# stage2 it built, which lives outside _build/selfhost/generations).
. scripts/resolve_stage2.sh
STAGE2="${EMIT_ASYNC_FIXTURE_STAGE2:-}"
if [ -z "$STAGE2" ]; then
  STAGE2="$(resolve_stage2_generation emit-async-lift-fixture "$PWD")" || STAGE2=""
fi
[ -s "$STAGE2" ] || { echo "emit-async-lift-fixture: no stage2 (${STAGE2:-none found}) -- run: bash scripts/generations.sh build" >&2; exit 1; }
OUT="${1:-fixtures/async_lift_run42.component.wasm}"
WORK="_build/_emit_async_fixture"; rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/emit.vibe" <<'EOF'
import @vibe/compiler/core {
  bytebuf_new, bytebuf_push, bytebuf_push_section, bytebuf_push_vec_header, bytebuf_to_bytes
}
import @vibe/compiler/codegen/component {
  comp_emit_component_wasm_async_trampolined_p1
}
import @vibe/compiler/codegen/wasm_emit {
  emit_header, emit_func_type_raw, emit_function_section, emit_export_section, emit_i64_const, emit_code_section, emit_name
}
let build_core = () -> Bytes {
  let out = bytebuf_new()
  emit_header(out)
  let tc = bytebuf_new()
  bytebuf_push_vec_header(buf = tc, count = 2)
  emit_func_type_raw(buf = tc, param_types = [127, 127, 127, 127], result_types = [127])
  emit_func_type_raw(buf = tc, param_types = [126], result_types = [126])
  bytebuf_push_section(out = out, section_id = 1, content = tc)
  let ic = bytebuf_new()
  bytebuf_push_vec_header(buf = ic, count = 1)
  emit_name(buf = ic, name = "wasi_snapshot_preview1")
  emit_name(buf = ic, name = "fd_write")
  bytebuf_push(buf = ic, byte = 0)
  bytebuf_push(buf = ic, byte = 0)
  bytebuf_push_section(out = out, section_id = 2, content = ic)
  emit_function_section(out = out, type_indices = [1])
  emit_export_section(out = out, name = "run", func_idx = 1)
  let body = bytebuf_new()
  emit_i64_const(buf = body, value = 42)
  emit_code_section(out = out, bodies = [body])
  bytebuf_to_bytes(out)
}
export let main = () -> Int with Fs {
  let comp = comp_emit_component_wasm_async_trampolined_p1(main_core_wasm = build_core(), export_name = "run", comp_result_valtype = 120)
  Fs::write_bytes("_build/_emit_async_fixture/out.component.wasm", bytes = comp)
  Bytes::length(comp)
}
EOF
# Each step reports what failed: this script used to send both to /dev/null,
# so a driver that no longer compiled exited 1 with no message at all (#3873).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  "$WORK/emit.vibe" "$WORK/emit.wasm" main >"$WORK/compile.log" 2>&1 || {
  echo "emit-async-lift-fixture: the driver did not compile:" >&2
  { cat "$WORK/emit.wasm.diag" 2>/dev/null; echo; cat "$WORK/compile.log" 2>/dev/null; } | tail -n 15 >&2
  exit 1
}
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$WORK/emit.wasm" >"$WORK/run.log" 2>&1 || {
  echo "emit-async-lift-fixture: the driver did not run:" >&2
  tail -n 15 "$WORK/run.log" >&2
  exit 1
}
[ -s "$WORK/out.component.wasm" ] || { echo "emit-async-lift-fixture: the driver wrote no component" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$WORK/out.component.wasm" "$OUT"
rm -rf "$WORK"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
