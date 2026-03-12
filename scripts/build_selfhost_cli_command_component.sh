#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_COMPONENT="${1:-$PROJECT_ROOT/dist/selfhost_cli_command.component.wasm}"
OUT_WIT="${2:-${OUT_COMPONENT%.wasm}.wit}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_cli_command_entry.vibe}"
TMP_DIR="$(mktemp -d /tmp/vibe_selfhost_cli_command_component.XXXXXX)"

cleanup() {
  if [ "${VIBE_KEEP_TMP:-0}" = "1" ]; then
    echo "keeping tmp dir: $TMP_DIR" >&2
    return
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

if [ -x "/Users/mz/.cargo/bin/cargo" ]; then
  export PATH="/Users/mz/.cargo/bin:$PATH"
fi

require_cmd cargo
require_cmd wasm-tools
require_cmd wac

mkdir -p "$TMP_DIR/src" "$(dirname "$OUT_COMPONENT")" "$(dirname "$OUT_WIT")"

PLUG_COMPONENT="$TMP_DIR/selfhost_cli_string_lift.component.wasm"
ADAPTER_COMPONENT="$TMP_DIR/selfhost_cli_command_adapter.component.wasm"
ADAPTER_EMBEDDED_WASM="$TMP_DIR/selfhost_cli_command_adapter.embedded.wasm"
ADAPTER_WIT_DIR="$TMP_DIR/wit"
ADAPTER_WIT_DEPS_DIR="$ADAPTER_WIT_DIR/deps"
mkdir -p "$ADAPTER_WIT_DEPS_DIR"

RELEASE_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
moon build --target native --release --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
VIBE_CMD=("$RELEASE_VIBE_EXE" compile)

"${VIBE_CMD[@]}" --component-string-lift "$ENTRY_PATH" -o "$PLUG_COMPONENT"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_selfhost_cli_command_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.53.1", default-features = false, features = ["macros", "realloc", "bitflags"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:selfhost-cli-command-adapter;

      world adapter {
        import compile-cli-hex: func(source: string, entry-name: string) -> string;
        include wasi:cli/command@0.2.6;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit",
    world: "vibe:selfhost-cli-command-adapter/adapter",
    pub_export_macro: true,
    generate_all,
});

struct Component;

fn tail_args(count: usize) -> Result<Vec<String>, ()> {
    let args = wasi::cli::environment::get_arguments();
    if args.len() < count {
        Err(())
    } else {
        Ok(args[args.len() - count..].to_vec())
    }
}

fn debug_enabled() -> bool {
    wasi::cli::environment::get_environment()
        .into_iter()
        .any(|(key, value)| key == "VIBE_SELFHOST_CLI_COMMAND_DEBUG" && value == "1")
}

fn debug_log(message: &str) {
    if !debug_enabled() {
        return;
    }
    let stream = wasi::cli::stderr::get_stderr();
    let _ = stream.blocking_write_and_flush(message.as_bytes());
    let _ = stream.blocking_write_and_flush(b"\n");
}

fn read_stdin_all() -> Result<String, ()> {
    let stream = wasi::cli::stdin::get_stdin();
    let mut out = Vec::new();
    loop {
        match stream.blocking_read(4096) {
            Ok(chunk) => {
                if chunk.is_empty() {
                    break;
                }
                out.extend_from_slice(&chunk);
            }
            Err(wasi::io::streams::StreamError::Closed) => break,
            Err(_) => return Err(()),
        }
    }
    String::from_utf8(out).map_err(|_| ())
}

fn write_stdout_all(bytes: &[u8]) -> Result<(), ()> {
    let stream = wasi::cli::stdout::get_stdout();
    for chunk in bytes.chunks(4096) {
        stream.blocking_write_and_flush(chunk).map_err(|_| ())?;
    }
    Ok(())
}

fn decode_hex_nibble(byte: u8) -> Result<u8, ()> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(()),
    }
}

fn decode_hex_string(hex: &str) -> Result<Vec<u8>, ()> {
    let bytes = hex.as_bytes();
    if bytes.is_empty() || bytes.len() % 2 != 0 {
        return Err(());
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let hi = decode_hex_nibble(bytes[i])?;
        let lo = decode_hex_nibble(bytes[i + 1])?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

impl exports::wasi::cli::run::Guest for Component {
    fn run() -> Result<(), ()> {
        debug_log("run:start");
        let args = tail_args(1)?;
        debug_log("run:args");
        let entry_name = &args[0];
        let source = read_stdin_all()?;
        debug_log("run:stdin");
        let hex = compile_cli_hex(&source, entry_name);
        debug_log("run:hex-ready");
        let output = decode_hex_string(&hex)?;
        debug_log("run:output-ready");
        write_stdout_all(&output)
    }
}

export!(Component);
EOF

cat >"$ADAPTER_WIT_DIR/world.wit" <<'EOF'
package vibe:selfhost-cli-command-adapter;

world adapter {
  import compile-cli-hex: func(source: string, entry-name: string) -> string;
  include wasi:cli/command@0.2.6;
}
EOF

cp \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/cli.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/clocks.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/filesystem.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/io.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/random.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/sockets.wit" \
  "$ADAPTER_WIT_DEPS_DIR/"

pushd "$TMP_DIR" >/dev/null
PATH="$HOME/.cargo/bin:$PATH" cargo build --target wasm32-unknown-unknown --release >/dev/null
wasm-tools component embed "$ADAPTER_WIT_DIR" \
  target/wasm32-unknown-unknown/release/vibe_selfhost_cli_command_adapter.wasm \
  --world adapter \
  -o "$ADAPTER_EMBEDDED_WASM"
wasm-tools component new "$ADAPTER_EMBEDDED_WASM" -o "$ADAPTER_COMPONENT"
popd >/dev/null

wasm-tools validate --features all "$ADAPTER_COMPONENT" >/dev/null

wac plug \
  --plug "$PLUG_COMPONENT" \
  -o "$OUT_COMPONENT" \
  "$ADAPTER_COMPONENT"
wasm-tools validate --features all "$OUT_COMPONENT" >/dev/null
wasm-tools component wit "$OUT_COMPONENT" >"$OUT_WIT"

echo "wrote $OUT_COMPONENT"
echo "wrote $OUT_WIT"
