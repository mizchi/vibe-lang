#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/vibe_body_stream_probe_test.XXXXXX")"
cleanup() { rm -rf "$FAKE_BIN"; }
trap cleanup EXIT

cat >"$FAKE_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p target/wasm32-unknown-unknown/release
: >target/wasm32-unknown-unknown/release/vibe_body_stream_probe_adapter.wasm
EOF

cat >"$FAKE_BIN/wasm-tools" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2" = "component wit" ]; then
  case "$3" in
    *adapter.component.wasm)
      printf '%s\n' 'world root {' \
        '  import wasi:http/types@0.3.0;' \
        '  import handler: func(method: string, url: string, headers: string, body: stream<u8>) -> string;' \
        '}'
      ;;
    *)
      printf '%s\n' 'world root {' '  import wasi:http/types@0.3.0;' '}'
      ;;
  esac
  exit 0
fi
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
[ -z "$out" ] || : >"$out"
EOF

cat >"$FAKE_BIN/wac" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
: >"$out"
EOF

# Simulate the collision from the review: the process spawned by the gate
# loses the bind race and exits, while an incumbent endpoint answers "ok".
cat >"$FAKE_BIN/wasmtime" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'wasmtime 47.0.2'; exit 0; fi
exit 1
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) printf '200' ;;
  *" -o /dev/null "*) : ;;
  *) printf 'ok' ;;
esac
EOF

chmod +x "$FAKE_BIN"/*

set +e
PATH="$FAKE_BIN:$PATH" bash "$SCRIPT_DIR/test_http_body_stream_probe_gate.sh" \
  >"$FAKE_BIN/out" 2>"$FAKE_BIN/err"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "FAIL: probe accepted an incumbent endpoint after its own server exited" >&2
  cat "$FAKE_BIN/out" >&2
  exit 1
fi

if ! grep -q 'test_http_body_stream_probe_gate.sh' "$SCRIPT_DIR/test_wasi_p3_guarantee_gate.sh"; then
  echo "FAIL: body-stream probe is not registered in the WASI p3 guarantee gate" >&2
  exit 1
fi

echo "http body stream probe gate regression: PASS"
