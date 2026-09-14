#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKFIRE_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/.github/pkfire-version")"
PKL_VERSION=0.32.1
PKFIRE_INSTALL_DIR="${PKFIRE_INSTALL_DIR:-$HOME/.local/share/vibe-pkfire}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) pkf_platform=linux-amd64; pkl_platform=linux-amd64 ;;
  Linux-aarch64) pkf_platform=linux-arm64; pkl_platform=linux-aarch64 ;;
  Darwin-arm64) pkf_platform=darwin-arm64; pkl_platform=macos-aarch64 ;;
  *) echo "unsupported pkfire platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Download into files: a failed or retried transfer must not feed partial bytes
# to tar, or replace either installed executable before both are validated.
curl -fsSL --retry 5 --retry-all-errors -o "$tmp_dir/pkf.tar.gz" \
  "https://github.com/mizchi/pkfire/releases/download/pkfire@${PKFIRE_VERSION}/pkf-${pkf_platform}.tar.gz"
tar -xzf "$tmp_dir/pkf.tar.gz" -C "$tmp_dir"
curl -fsSL --retry 5 --retry-all-errors -o "$tmp_dir/pkl" \
  "https://github.com/apple/pkl/releases/download/${PKL_VERSION}/pkl-${pkl_platform}"
chmod +x "$tmp_dir/pkf" "$tmp_dir/pkl"

got="$("$tmp_dir/pkf" version | tr -d '[:space:]')"
if [ "$got" != "$PKFIRE_VERSION" ]; then
  echo "pkfire pin not honoured: expected $PKFIRE_VERSION, got $got" >&2
  exit 1
fi
got="$("$tmp_dir/pkl" --version)"
case "$got" in
  "Pkl $PKL_VERSION ("*) ;;
  *) echo "Pkl pin not honoured: expected $PKL_VERSION, got $got" >&2; exit 1 ;;
esac

install -d "$PKFIRE_INSTALL_DIR/bin"
install -m 0755 "$tmp_dir/pkf" "$PKFIRE_INSTALL_DIR/bin/pkf"
install -m 0755 "$tmp_dir/pkl" "$PKFIRE_INSTALL_DIR/bin/pkl"
echo "[pkfire] installed pkf $PKFIRE_VERSION + Pkl $PKL_VERSION"
