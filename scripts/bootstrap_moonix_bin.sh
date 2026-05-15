#!/usr/bin/env bash
set -euo pipefail

# Try to produce a usable moonix executable from a local moonix checkout.

MOONIX_SRC_DEFAULT="$HOME/ghq/github.com/mizchi/moonix"
MOONIX_SRC="${MOONIX_SRC:-$MOONIX_SRC_DEFAULT}"
INSTALL_BIN="${MOONIX_INSTALL_BIN:-$HOME/.local/bin/moonix}"

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [moonix-src-dir]" >&2
  exit 1
fi
if [ "$#" -eq 1 ]; then
  MOONIX_SRC="$1"
fi

if [ ! -d "$MOONIX_SRC" ]; then
  echo "moonix source not found: $MOONIX_SRC" >&2
  echo "set MOONIX_SRC or install moonix binary manually" >&2
  exit 1
fi

mkdir -p "$(dirname "$INSTALL_BIN")"

if [ -x "$INSTALL_BIN" ]; then
  echo "$INSTALL_BIN"
  exit 0
fi

find_built_bin() {
  local src="$1"
  local candidate=""

  if [ -x "$src/target/release/moonix" ]; then
    echo "$src/target/release/moonix"
    return 0
  fi
  if [ -x "$src/hosts/wasmtime/target/release/moonix" ]; then
    echo "$src/hosts/wasmtime/target/release/moonix"
    return 0
  fi
  if [ -x "$src/target/native/release/build/moonix/moonix.exe" ]; then
    echo "$src/target/native/release/build/moonix/moonix.exe"
    return 0
  fi
  candidate="$(find "$src/_build/native/release/build" -maxdepth 5 -type f -name 'moonix*.exe' 2>/dev/null | head -n 1 || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    echo "$candidate"
    return 0
  fi
  return 1
}

try_build() {
  local src="$1"
  local built=""

  if command -v pkf >/dev/null 2>&1; then
    (
      cd "$src"
      set +e
      pkf run install >/dev/null 2>&1
      local st=$?
      set -e
      if [ "$st" -eq 0 ]; then
        exit 0
      fi
      set +e
      pkf run build >/dev/null 2>&1
      st=$?
      set -e
      [ "$st" -eq 0 ]
    ) || true
  fi

  if command -v moon >/dev/null 2>&1; then
    (
      cd "$src"
      set +e
      moon build --target native src/cmd/moonix >/dev/null 2>&1
      local st=$?
      set -e
      [ "$st" -eq 0 ]
    ) || true
  fi

  if command -v cargo >/dev/null 2>&1; then
    (
      cd "$src"
      set +e
      cargo build --release --manifest-path hosts/wasmtime/Cargo.toml --bin moonix >/dev/null 2>&1
      local st=$?
      set -e
      [ "$st" -eq 0 ]
    ) || true
  fi

  if built="$(find_built_bin "$src")"; then
    cp "$built" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    echo "$INSTALL_BIN"
    return 0
  fi
  return 1
}

if try_build "$MOONIX_SRC"; then
  exit 0
fi

echo "failed to bootstrap moonix binary from: $MOONIX_SRC" >&2
echo "moonix repository appears to have no CLI build target yet." >&2
echo "expected one of:" >&2
echo "  - pkf run install (installs moonix to ~/.local/bin/moonix)" >&2
echo "  - moon build --target native src/cmd/moonix" >&2
echo "  - cargo build --release --manifest-path hosts/wasmtime/Cargo.toml --bin moonix" >&2
exit 1
