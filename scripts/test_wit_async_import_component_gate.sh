#!/usr/bin/env bash
# #2064: emit the complete synthetic-core composition for the first
# WIT-derived async import and validate that it owns a versioned interface
# import instead of a runner-private root function import.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/_build/wit_async_import_component_gate"
mkdir -p "$OUT"

cat >"$OUT/emit_test.vibe" <<'EOF'
import @vibe/compiler/entry/source_compile/wasi_only {
  comp_emit_component_wasm_async_wit_future_fixture,
  comp_emit_wit_async_future_import_surface,
  comp_emit_wit_outbound_http_dual_fetch_surface,
  comp_emit_wit_http_error_code_type_surface,
  comp_emit_wit_http_client_send_surface,
  comp_wit_outbound_http_response_descriptor
}

fn write_hex(bytes: Bytes, path: String) -> Unit with Fs {
  let out = StringBuilder::new()
  let mut i = 0
  while i < Bytes::length(bytes) {
    let byte = Bytes::get(bytes, i)
    let hi = (byte >> 4)&15
    let lo = byte&15
    StringBuilder::push(out, String::from_char_code(if hi < 10 { 48 + hi } else { 87 + hi }))
    StringBuilder::push(out, String::from_char_code(if lo < 10 { 48 + lo } else { 87 + lo }))
    i = i + 1
  }
  Fs::write_file(path, StringBuilder::freeze(out))
}

test "emit composed fixture" {
  write_hex(
    comp_emit_component_wasm_async_wit_future_fixture(),
    "_build/wit_async_import_component_gate/component.hex"
  )
  write_hex(
    comp_emit_wit_async_future_import_surface(
      "example:prices/api@1.0.0",
      "get-price-record",
      "future<record{amount:s64,currency:string}>"
    ),
    "_build/wit_async_import_component_gate/record.hex"
  )
  write_hex(
    comp_emit_wit_async_future_import_surface(
      "example:prices/api@1.0.0",
      "get-price-band",
      "future<enum{cheap,expensive}>"
    ),
    "_build/wit_async_import_component_gate/enum.hex"
  )
  write_hex(
    comp_emit_wit_async_future_import_surface(
      "wasi:http/outgoing-handler@0.3.0",
      "handle",
      comp_wit_outbound_http_response_descriptor()
    ),
    "_build/wit_async_import_component_gate/http-response.hex"
  )
  write_hex(
    comp_emit_wit_outbound_http_dual_fetch_surface(),
    "_build/wit_async_import_component_gate/http-dual.hex"
  )
  write_hex(
    comp_emit_wit_http_error_code_type_surface(),
    "_build/wit_async_import_component_gate/http-error-code.hex"
  )
  write_hex(
    comp_emit_wit_http_client_send_surface(),
    "_build/wit_async_import_component_gate/http-client.hex"
  )
}
EOF

bash scripts/vibe_test.sh "$OUT/emit_test.vibe"
rm -f "$OUT/component.wasm" "$OUT/record.wasm" "$OUT/enum.wasm" "$OUT/http-response.wasm" "$OUT/http-dual.wasm" "$OUT/http-error-code.wasm" "$OUT/http-client.wasm"
xxd -r -p "$OUT/component.hex" "$OUT/component.wasm"
wasm-tools validate --features all "$OUT/component.wasm"
wasm-tools print "$OUT/component.wasm" >"$OUT/component.wat"
xxd -r -p "$OUT/record.hex" "$OUT/record.wasm"
xxd -r -p "$OUT/enum.hex" "$OUT/enum.wasm"
xxd -r -p "$OUT/http-response.hex" "$OUT/http-response.wasm"
xxd -r -p "$OUT/http-dual.hex" "$OUT/http-dual.wasm"
xxd -r -p "$OUT/http-error-code.hex" "$OUT/http-error-code.wasm"
xxd -r -p "$OUT/http-client.hex" "$OUT/http-client.wasm"
wasm-tools validate --features all "$OUT/record.wasm"
wasm-tools validate --features all "$OUT/enum.wasm"
wasm-tools validate --features all "$OUT/http-response.wasm"
wasm-tools validate --features all "$OUT/http-dual.wasm"
wasm-tools validate --features all "$OUT/http-error-code.wasm"
wasm-tools validate --features all "$OUT/http-client.wasm"
wasm-tools print "$OUT/record.wasm" >"$OUT/record.wat"
wasm-tools print "$OUT/enum.wasm" >"$OUT/enum.wat"
wasm-tools print "$OUT/http-response.wasm" >"$OUT/http-response.wat"
wasm-tools print "$OUT/http-dual.wasm" >"$OUT/http-dual.wat"
wasm-tools print "$OUT/http-error-code.wasm" >"$OUT/http-error-code.wat"
wasm-tools print "$OUT/http-client.wasm" >"$OUT/http-client.wat"
grep -Fq '(import "example:prices/api@1.0.0" (instance' "$OUT/component.wat"
grep -Fq '(export (;0;) "get-price" (func' "$OUT/component.wat"
grep -Fq '(export (;1;) "get-tax" (func' "$OUT/component.wat"
grep -Fq '(import "example:inventory/api@2.1.0" (instance' "$OUT/component.wat"
grep -Fq '"get-stock" (func' "$OUT/component.wat"
[ "$(grep -Fc '(import "example:prices/api@1.0.0" (instance' "$OUT/component.wat")" = 1 ]
if grep -Fq '(import "get-price" (func' "$OUT/component.wat"; then
  echo "WIT async import gate FAILED: get-price remained a root function import" >&2
  exit 1
fi
grep -Fq '(record (field "amount" s64) (field "currency" string))' "$OUT/record.wat"
grep -Fq '(future 0)' "$OUT/record.wat"
grep -Fq '(enum "cheap" "expensive")' "$OUT/enum.wat"
grep -Fq '(future 0)' "$OUT/enum.wat"
grep -Fq '(import "wasi:http/types@0.3.0" (instance' "$OUT/http-response.wat"
grep -Fq '(import "wasi:http/outgoing-handler@0.3.0" (instance' "$OUT/http-response.wat"
grep -Fq '(stream u8)' "$OUT/http-response.wat"
grep -Fq '(record (field "status" s32) (field "headers" string) (field "body" 0))' "$OUT/http-response.wat"
grep -Fq '(record (field "method" string) (field "url" string) (field "headers" string) (field "body" 0))' "$OUT/http-dual.wat"
grep -Fq '(record (field "status" s32) (field "headers" string) (field "body" 0))' "$OUT/http-dual.wat"
[ "$(grep -Fc '(func async (param "request" 0) (result 2))' "$OUT/http-dual.wat")" = 2 ]
grep -Fq '(export (;0;) "fetch-left" (func' "$OUT/http-dual.wat"
grep -Fq '(export (;1;) "fetch-right" (func' "$OUT/http-dual.wat"
grep -Fq '(case "DNS-error" 3)' "$OUT/http-error-code.wat"
grep -Fq '(case "TLS-alert-received" 6)' "$OUT/http-error-code.wat"
grep -Fq '(case "internal-error" 0)' "$OUT/http-error-code.wat"
grep -Fq '"error-code" (type (eq 12))' "$OUT/http-error-code.wat"
grep -Fq '"request" (type (sub resource))' "$OUT/http-client.wat"
grep -Fq '"response" (type (sub resource))' "$OUT/http-client.wat"
grep -Fq '(type (;3;) (own 1))' "$OUT/http-client.wat"
grep -Fq '(type (;4;) (result 3 (error 2)))' "$OUT/http-client.wat"
grep -Fq '(type (;5;) (own 0))' "$OUT/http-client.wat"
grep -Fq '(func async (param "request" 5) (result 4))' "$OUT/http-client.wat"

# --- a REAL program on the same route (#2064) -------------------------------
# Everything above composes a hand-built core. Here the import set comes from
# WIT text: fixtures/wit_future_import/prices_bindings.vibe is the
# `from_wit_future_imports` derivation of prices.wit (from_wit_test.vibe pins
# that), and main.vibe awaits both bindings. linked_compile must emit the
# `wit_future_get$` metadata imports and the composer must import both
# functions from ONE versioned `example:prices/api@1.0.0` instance.
#
# The checkout's compiler, not the seed: the route is new, and a seed that
# predates it would refuse the address (`invalid import name`) -- which is
# the answer about a different compiler, not a pass or fail about this one.
COMPILER="${VIBE_WIT_ASYNC_IMPORT_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
fi
if [ ! -f "$COMPILER" ]; then
  echo "WIT async import gate FAILED: no stage2 compiler (set VIBE_WIT_ASYNC_IMPORT_GATE_COMPILER or run pkf run generation)" >&2
  exit 1
fi
PROG_DIR="$OUT/program"
rm -rf "$PROG_DIR"
mkdir -p "$PROG_DIR"
cp fixtures/wit_future_import/main.vibe fixtures/wit_future_import/prices_bindings.vibe "$PROG_DIR/"
# The program imports its bindings, so it compiles on the FS lane, which
# composes the host-future adapter itself when a `run` entry's core imports a
# host future (`maybe_wrap_stdin_provider_core`), as the single-file lane does.
VIBE_PREOPEN_DIR="$ROOT" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" "$PROG_DIR/main.vibe" "$PROG_DIR/main.wasm" run >/dev/null 2>&1 || true
if [ ! -s "$PROG_DIR/main.wasm" ]; then
  echo "WIT async import gate FAILED: fixtures/wit_future_import/main.vibe did not compile" >&2
  cat "$PROG_DIR/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! od -A n -t x1 -N 8 "$PROG_DIR/main.wasm" | tr -d ' \n' | grep -q '^0061736d0d000100$'; then
  echo "WIT async import gate FAILED: the file lane left a core module, not a component" >&2
  exit 1
fi
# The embedded core must carry the WIT-addressed metadata imports and no root ones.
for want in 'wit_future_get$example:prices/api@1.0.0#get-price' 'wit_future_get$example:prices/api@1.0.0#get-tax'; do
  grep -aFq "$want" "$PROG_DIR/main.wasm" || {
    echo "WIT async import gate FAILED: the core lacks the metadata import $want" >&2
    exit 1
  }
done
if grep -aFq 'host_future_get$' "$PROG_DIR/main.wasm"; then
  echo "WIT async import gate FAILED: a WIT-addressed future was emitted as a root host_future_get import" >&2
  exit 1
fi
wasm-tools validate --features all "$PROG_DIR/main.wasm"
wasm-tools print "$PROG_DIR/main.wasm" >"$PROG_DIR/main.wat"
[ "$(grep -Fc '(import "example:prices/api@1.0.0" (instance' "$PROG_DIR/main.wat")" = 1 ] || {
  echo "WIT async import gate FAILED: the program does not import exactly one example:prices/api@1.0.0 instance" >&2
  exit 1
}
grep -Fq '"get-price" (func' "$PROG_DIR/main.wat"
grep -Fq '"get-tax" (func' "$PROG_DIR/main.wat"
if grep -Eq '\(import "(get-price|get-tax)" \(func' "$PROG_DIR/main.wat"; then
  echo "WIT async import gate FAILED: a WIT-addressed future became a root function import" >&2
  exit 1
fi
echo "WIT async import component gate OK"
