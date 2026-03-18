#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_COMPONENT="${1:-$PROJECT_ROOT/dist/selfhost_cli_direct.component.wasm}"
OUT_WIT="${2:-${OUT_COMPONENT%.wasm}.wit}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_cli_direct_component_entry.vibe}"
RELEASE_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
TMP_DIR="$(mktemp -d /tmp/vibe_selfhost_cli_direct_component.XXXXXX)"

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

PLUG_COMPONENT="$TMP_DIR/selfhost_cli_preview2.component.wasm"
PLUG_WIT="$TMP_DIR/selfhost_cli_preview2.component.wit"
ADAPTER_COMPONENT="$TMP_DIR/selfhost_cli_direct_adapter.component.wasm"
ADAPTER_EMBEDDED_WASM="$TMP_DIR/selfhost_cli_direct_adapter.embedded.wasm"
ADAPTER_WIT_DIR="$TMP_DIR/wit"
ADAPTER_WIT_DEPS_DIR="$ADAPTER_WIT_DIR/deps"
mkdir -p "$ADAPTER_WIT_DEPS_DIR"

if [ ! -x "$RELEASE_VIBE_EXE" ]; then
  moon build --target native --release --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
fi

"$RELEASE_VIBE_EXE" compile --component-string-lift "$ENTRY_PATH" -o "$PLUG_COMPONENT"
wasm-tools validate --features exceptions "$PLUG_COMPONENT" >/dev/null
wasm-tools component wit "$PLUG_COMPONENT" >"$PLUG_WIT"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_selfhost_cli_direct_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.54.0", default-features = false, features = ["macros", "realloc", "bitflags"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
mod bindings {
    wit_bindgen::generate!({
        inline: r#"
          package vibe:selfhost-cli-direct-adapter;

          world adapter {
            import compile-cli-hex: func(source: string, entry-name: string, mode: string) -> string;
            import wasi:filesystem/types@0.2.6;
            import wasi:filesystem/preopens@0.2.6;
            export run-cli-request: func(input-path: string, output-path: string, entry-name: string, mode: string) -> s32;
          }
        "#,
        path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit",
        world: "vibe:selfhost-cli-direct-adapter/adapter",
        generate_all,
    });
}

use bindings::wasi::filesystem;
use bindings::compile_cli_hex;
use bindings::Guest;

struct Component;

fn root_dir() -> Result<filesystem::types::Descriptor, ()> {
    filesystem::preopens::get_directories()
        .into_iter()
        .next()
        .map(|(dir, _)| dir)
        .ok_or(())
}

fn read_payload(path: &str) -> Result<String, ()> {
    let root = root_dir()?;
    let file = root
        .open_at(
            filesystem::types::PathFlags::empty(),
            path,
            filesystem::types::OpenFlags::empty(),
            filesystem::types::DescriptorFlags::READ,
        )
        .map_err(|_| ())?;
    let stat = file.stat().map_err(|_| ())?;
    let (bytes, _) = file.read(stat.size, 0).map_err(|_| ())?;
    String::from_utf8(bytes).map_err(|_| ())
}

fn decode_hex_digit(byte: u8) -> Result<u8, ()> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(()),
    }
}

fn decode_hex_bytes(hex: &str) -> Result<Vec<u8>, ()> {
    let raw = hex.as_bytes();
    if raw.is_empty() || raw.len() % 2 != 0 {
        return Err(());
    }
    let mut out = Vec::with_capacity(raw.len() / 2);
    let mut i = 0usize;
    while i < raw.len() {
        let hi = decode_hex_digit(raw[i])?;
        let lo = decode_hex_digit(raw[i + 1])?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

fn compile_bytes(payload: &str, entry_name: &str, mode: &str) -> Result<Vec<u8>, ()> {
    let hex = compile_cli_hex(payload, entry_name, mode);
    decode_hex_bytes(&hex)
}

fn write_output(path: &str, bytes: &[u8]) -> Result<(), ()> {
    let root = root_dir()?;
    let file = root
        .open_at(
            filesystem::types::PathFlags::empty(),
            path,
            filesystem::types::OpenFlags::CREATE | filesystem::types::OpenFlags::TRUNCATE,
            filesystem::types::DescriptorFlags::WRITE,
        )
        .map_err(|_| ())?;
    let mut offset = 0usize;
    while offset < bytes.len() {
        let written = file
            .write(&bytes[offset..], offset as u64)
            .map_err(|_| ())?;
        if written == 0 {
            return Err(());
        }
        offset += written as usize;
    }
    file.sync().map_err(|_| ())?;
    Ok(())
}

impl Guest for Component {
    fn run_cli_request(input_path: String, output_path: String, entry_name: String, mode: String) -> i32 {
        match (|| -> Result<(), ()> {
            let payload = read_payload(&input_path)?;
            let bytes = compile_bytes(&payload, &entry_name, &mode)?;
            write_output(&output_path, &bytes)?;
            Ok(())
        })() {
            Ok(()) => 0,
            Err(()) => -1,
        }
    }
}

bindings::export!(Component with_types_in bindings);
EOF

cat >"$ADAPTER_WIT_DIR/world.wit" <<'EOF'
package vibe:selfhost-cli-direct-adapter;

world adapter {
  import compile-cli-hex: func(source: string, entry-name: string, mode: string) -> string;
  import wasi:filesystem/types@0.2.6;
  import wasi:filesystem/preopens@0.2.6;
  export run-cli-request: func(input-path: string, output-path: string, entry-name: string, mode: string) -> s32;
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
  target/wasm32-unknown-unknown/release/vibe_selfhost_cli_direct_adapter.wasm \
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
