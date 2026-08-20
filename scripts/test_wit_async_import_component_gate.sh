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
echo "WIT async import component gate OK"
