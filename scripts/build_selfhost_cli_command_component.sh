#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_COMPONENT="${1:-$PROJECT_ROOT/dist/selfhost_cli_command.component.wasm}"
OUT_WIT="${2:-${OUT_COMPONENT%.wasm}.wit}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_cli_command_entry.vibe}"
TMP_DIR="$(mktemp -d /tmp/vibe_selfhost_cli_command_component.XXXXXX)"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${VIBE_SELFHOST_CLI_COMMAND_CARGO_TARGET_DIR:-$PROJECT_ROOT/_build/cargo-target/selfhost_component_adapters}}"
ADAPTER_LOCK_FILE="${VIBE_SELFHOST_CLI_COMMAND_CARGO_LOCK:-$PROJECT_ROOT/_build/cargo-locks/selfhost_cli_command_adapter.Cargo.lock}"
ADAPTER_BUILD_LOCK_DIR="${VIBE_SELFHOST_CLI_COMMAND_BUILD_LOCK:-$PROJECT_ROOT/_build/locks/selfhost_cli_command_adapter.lock}"
ADAPTER_BUILD_LOCK_HELD=0
export CARGO_TARGET_DIR

cleanup() {
  if [ "$ADAPTER_BUILD_LOCK_HELD" = "1" ]; then
    rmdir "$ADAPTER_BUILD_LOCK_DIR" 2>/dev/null || true
  fi
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

acquire_adapter_build_lock() {
  mkdir -p "$(dirname "$ADAPTER_BUILD_LOCK_DIR")"
  local attempts=0
  local max_attempts=1500
  while ! mkdir "$ADAPTER_BUILD_LOCK_DIR" 2>/dev/null; do
    sleep 0.2
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo "timed out waiting for adapter build lock: $ADAPTER_BUILD_LOCK_DIR" >&2
      exit 1
    fi
  done
  ADAPTER_BUILD_LOCK_HELD=1
}

if [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
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

if [ -n "${VIBE_BIN:-}" ]; then
  RELEASE_VIBE_EXE="$VIBE_BIN"
  if [ ! -x "$RELEASE_VIBE_EXE" ]; then
    echo "VIBE_BIN is not executable: $RELEASE_VIBE_EXE" >&2
    exit 1
  fi
else
  export VIBE_MOON_WARN_LIST="${VIBE_MOON_WARN_LIST:--29-55-67-23-24-7-1}"
  source "$SCRIPT_DIR/ensure_native_cli.sh"
  RELEASE_VIBE_EXE="$VIBE_CLI_BIN"
fi

"$RELEASE_VIBE_EXE" compile --component-string-lift "$ENTRY_PATH" -o "$PLUG_COMPONENT"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_selfhost_cli_command_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.54.0", default-features = false, features = ["macros", "realloc", "bitflags"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:selfhost-cli-command-adapter;

      world adapter {
        import compile-cli-request: func(source: string, request: string) -> string;
        include wasi:cli/command@0.2.6;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit",
    world: "vibe:selfhost-cli-command-adapter/adapter",
    pub_export_macro: true,
    generate_all,
});

struct Component;

const HEX_CHUNK_BYTES: usize = 1024;

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
    if bytes.len() % 2 != 0 {
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

fn compile_bytes(source: &str, entry_name: &str, mode: &str) -> Result<Vec<u8>, ()> {
    let len_request = format!("len-mode:{mode}:{entry_name}");
    let byte_len = compile_cli_request(source, &len_request)
        .parse::<usize>()
        .map_err(|_| ())?;
    if byte_len == 0 {
        return Err(());
    }
    let mut out = Vec::with_capacity(byte_len);
    let chunk_count = byte_len.div_ceil(HEX_CHUNK_BYTES);
    for chunk_index in 0..chunk_count {
        let chunk_request = format!("hex-chunk-mode:{mode}:{entry_name}:{chunk_index}");
        let mut chunk = decode_hex_string(&compile_cli_request(source, &chunk_request))?;
        let remaining = byte_len - out.len();
        if chunk.len() > remaining {
            chunk.truncate(remaining);
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

impl exports::wasi::cli::run::Guest for Component {
    fn run() -> Result<(), ()> {
        let args = wasi::cli::environment::get_arguments();
        let argc = args.len();
        if argc == 0 {
            return Err(());
        }
        let last = args[argc - 1].clone();
        let (entry_name, mode) = if matches!(last.as_str(), "mvp" | "no-dce") {
            if argc < 2 {
                return Err(());
            }
            (args[argc - 2].clone(), last)
        } else {
            (last, "mvp".to_string())
        };
        let source = read_stdin_all()?;
        let output = compile_bytes(&source, &entry_name, &mode)?;
        write_stdout_all(&output)
    }
}

export!(Component);
EOF

cat >"$ADAPTER_WIT_DIR/world.wit" <<'EOF'
package vibe:selfhost-cli-command-adapter;

world adapter {
  import compile-cli-request: func(source: string, request: string) -> string;
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

acquire_adapter_build_lock
mkdir -p "$(dirname "$ADAPTER_LOCK_FILE")"
pushd "$TMP_DIR" >/dev/null
cargo_build_args=(--target wasm32-unknown-unknown --release)
if [ -f "$ADAPTER_LOCK_FILE" ]; then
  cp "$ADAPTER_LOCK_FILE" Cargo.lock
  cargo_build_args+=(--locked)
fi
PATH="$HOME/.cargo/bin:$PATH" cargo build "${cargo_build_args[@]}" >/dev/null
if [ ! -f "$ADAPTER_LOCK_FILE" ] && [ -f Cargo.lock ]; then
  cp Cargo.lock "$ADAPTER_LOCK_FILE"
fi
wasm-tools component embed "$ADAPTER_WIT_DIR" \
  "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/vibe_selfhost_cli_command_adapter.wasm" \
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
