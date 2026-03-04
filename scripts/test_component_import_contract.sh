#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="$(mktemp -d "/tmp/vibe_component_import_contract.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required" >&2
  exit 1
fi

cd "$PROJECT_ROOT"

STDIO_SRC="$TMP_DIR/stdio_probe.vibe"
STDIO_COMPONENT="$TMP_DIR/stdio_probe.component.wasm"
STDIO_WIT="$TMP_DIR/stdio_probe.component.wit"
STDIO_PRINT="$TMP_DIR/stdio_probe.component.wat"

cat >"$STDIO_SRC" <<'EOF'
let run = () -> Int with {Stdout} {
  stdout_write_char(65)
  1
}
run()
EOF

moon run --target native src/cmd/vibe -- compile --component "$STDIO_SRC" -o "$STDIO_COMPONENT"
moon run --target native src/cmd/vibe -- compile --wit-component "$STDIO_SRC" -o "$STDIO_WIT"
wasm-tools validate --features all "$STDIO_COMPONENT"
wasm-tools print "$STDIO_COMPONENT" >"$STDIO_PRINT"

rg -n '^\s*\(import "import-0" \(func' "$STDIO_PRINT" >/dev/null
rg -n '^\s*\(import "import-1" \(func' "$STDIO_PRINT" >/dev/null
rg -n '^\s*\(with "wasi:cli/stdout@0\.2\.0" \(instance' "$STDIO_PRINT" >/dev/null
rg -n '^\s*\(with "wasi:io/streams@0\.2\.0" \(instance' "$STDIO_PRINT" >/dev/null
if rg -n 'core-import-' "$STDIO_PRINT" >/dev/null; then
  echo "component import contract failed: legacy core-import-* names remain" >&2
  exit 1
fi
rg -n '^  import wasi:cli/stdout@0\.2\.0;$' "$STDIO_WIT" >/dev/null
rg -n '^  import wasi:io/streams@0\.2\.0;$' "$STDIO_WIT" >/dev/null

HTTP_SRC="$TMP_DIR/http_probe.vibe"
HTTP_COMPONENT="$TMP_DIR/http_probe.component.wasm"
HTTP_PRINT="$TMP_DIR/http_probe.component.wat"

cat >"$HTTP_SRC" <<'EOF'
let run = () -> Int with {Net} {
  let req = http_request("GET", "https://example.com", "", "")
  let status = http_response_status(req)
  http_close(req)
  status
}
run()
EOF

moon run --target native src/cmd/vibe -- compile --component --http-host-imports "$HTTP_SRC" -o "$HTTP_COMPONENT"
wasm-tools validate --features all "$HTTP_COMPONENT"
wasm-tools print "$HTTP_COMPONENT" >"$HTTP_PRINT"

rg -n '^\s*\(import "import-0" \(func' "$HTTP_PRINT" >/dev/null
rg -n '^\s*\(with "wasi:http/client@0\.3\.0-draft" \(instance' "$HTTP_PRINT" >/dev/null
rg -n '^\s*\(with "wasi:http/types@0\.3\.0-draft" \(instance' "$HTTP_PRINT" >/dev/null
if rg -n 'core-import-' "$HTTP_PRINT" >/dev/null; then
  echo "component import contract failed: legacy core-import-* names remain (http)" >&2
  exit 1
fi

echo "component import contract passed"
