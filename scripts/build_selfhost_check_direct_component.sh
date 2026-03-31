#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_COMPONENT="${1:-$PROJECT_ROOT/dist/selfhost_check_direct.component.wasm}"
OUT_WIT="${2:-${OUT_COMPONENT%.wasm}.wit}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_check_component_entry.vibe}"
RELEASE_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
TMP_DIR="$(mktemp -d /tmp/vibe_selfhost_check_direct_component.XXXXXX)"

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

if [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

require_cmd cargo
require_cmd wasm-tools
require_cmd wac

mkdir -p "$TMP_DIR/src" "$(dirname "$OUT_COMPONENT")" "$(dirname "$OUT_WIT")"

PLUG_COMPONENT="$TMP_DIR/selfhost_check_preview2.component.wasm"
ADAPTER_COMPONENT="$TMP_DIR/selfhost_check_direct_adapter.component.wasm"
ADAPTER_EMBEDDED_WASM="$TMP_DIR/selfhost_check_direct_adapter.embedded.wasm"
ADAPTER_WIT_DIR="$TMP_DIR/wit"
ADAPTER_WIT_DEPS_DIR="$ADAPTER_WIT_DIR/deps"
mkdir -p "$ADAPTER_WIT_DEPS_DIR"

if [ ! -x "$RELEASE_VIBE_EXE" ]; then
  moon build --target native --release --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
fi

"$RELEASE_VIBE_EXE" compile --component-string-lift "$ENTRY_PATH" -o "$PLUG_COMPONENT"
wasm-tools validate --features exceptions "$PLUG_COMPONENT" >/dev/null

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_selfhost_check_direct_adapter"
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
          package vibe:selfhost-check-direct-adapter;

          world adapter {
            import check-source-report: func(source: string) -> string;
            import wasi:filesystem/types@0.2.6;
            import wasi:filesystem/preopens@0.2.6;
            export run-check-request: func(input-path: string, output-path: string) -> s32;
          }
        "#,
        path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit",
        world: "vibe:selfhost-check-direct-adapter/adapter",
        generate_all,
    });
}

use bindings::check_source_report;
use bindings::wasi::filesystem;
use bindings::Guest;

struct Component;

fn root_dir() -> Result<filesystem::types::Descriptor, ()> {
    filesystem::preopens::get_directories()
        .into_iter()
        .next()
        .map(|(dir, _)| dir)
        .ok_or(())
}

fn read_source(path: &str) -> Result<String, ()> {
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

fn write_output(path: &str, report: &str) -> Result<(), ()> {
    let root = root_dir()?;
    let file = root
        .open_at(
            filesystem::types::PathFlags::empty(),
            path,
            filesystem::types::OpenFlags::CREATE | filesystem::types::OpenFlags::TRUNCATE,
            filesystem::types::DescriptorFlags::WRITE,
        )
        .map_err(|_| ())?;
    let bytes = report.as_bytes();
    let mut offset = 0usize;
    while offset < bytes.len() {
        let written = file.write(&bytes[offset..], offset as u64).map_err(|_| ())?;
        if written == 0 {
            return Err(());
        }
        offset += written as usize;
    }
    file.sync().map_err(|_| ())?;
    Ok(())
}

impl Guest for Component {
    fn run_check_request(input_path: String, output_path: String) -> i32 {
        match (|| -> Result<String, ()> {
            let source = read_source(&input_path)?;
            Ok(check_source_report(&source))
        })() {
            Ok(report) => {
                if write_output(&output_path, &report).is_err() {
                    -1
                } else if report == "ok" {
                    0
                } else {
                    1
                }
            }
            Err(()) => -1,
        }
    }
}

bindings::export!(Component with_types_in bindings);
EOF

cat >"$ADAPTER_WIT_DIR/world.wit" <<'EOF'
package vibe:selfhost-check-direct-adapter;

world adapter {
  import check-source-report: func(source: string) -> string;
  import wasi:filesystem/types@0.2.6;
  import wasi:filesystem/preopens@0.2.6;
  export run-check-request: func(input-path: string, output-path: string) -> s32;
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
  target/wasm32-unknown-unknown/release/vibe_selfhost_check_direct_adapter.wasm \
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
