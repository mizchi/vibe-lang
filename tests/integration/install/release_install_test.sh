#!/usr/bin/env bash
# Network-free regression for the release install path (#2678,
# docs/install.md "Updating"): a synthetic release directory served
# over file:// stands in for GitHub releases, a fake `viberun` stands in for
# the prebuilt runner (it only knows --precompile and --version), and the
# toolchain bundle is built from this checkout's launcher. What is proven:
#   * `install/install.sh --version X.Y.Z` installs with a PATH that holds
#     bash, curl, tar and the POSIX utilities the scripts use -- no git, no
#     cargo, no node;
#   * `vibe self update <version>|latest` installs a toolchain and switches
#     the default; `--no-default` does not; `--force` reinstalls; an installed
#     version is refused without it;
#   * an asset that does not match the release manifest is refused before
#     anything is moved into toolchains/ (no staging leftovers, the default
#     untouched), for the runner tarball and for the toolchain bundle;
#   * a release with no runner for this host names the targets it ships.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp" "$WORK/fakehome"

pass=0
fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 (expected '$2', got '$3')" >&2
    fail=$((fail + 1))
  fi
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# The same host -> target mapping the launcher uses.
os="$(uname -s)"; arch="$(uname -m)"
case "$arch" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; esac
case "$os" in Linux) TARGET="$arch-unknown-linux-gnu" ;; Darwin) TARGET="$arch-apple-darwin" ;; *) echo "unsupported host $os" >&2; exit 1 ;; esac

REL="$WORK/release"
RELEASE_URL="file://$REL/download"

# write_manifest <dir> <version> <runner-target>: the shape
# scripts/build_release_assets.sh writes (top-level keys at two spaces, the
# `runners` and `assets` entries at four).
write_manifest() {
  local d="$1" version="$2" rtarget="$3" tag="v$2"
  {
    printf '{\n'
    printf '  "tag": "%s",\n' "$tag"
    printf '  "version": "%s",\n' "$version"
    printf '  "commit": "0123456789abcdef0123456789abcdef01234567",\n'
    printf '  "wasmtime": "fake",\n'
    printf '  "compiler_wasm": "vibe-compiler-%s.wasm",\n' "$tag"
    printf '  "toolchain": "vibe-toolchain-%s.tar.gz",\n' "$tag"
    printf '  "runners": {\n'
    printf '    "%s": "viberun-%s-%s.tar.gz"\n' "$rtarget" "$tag" "$rtarget"
    printf '  },\n'
    printf '  "assets": {\n'
    printf '    "vibe-compiler-%s.wasm": "%s",\n' "$tag" "$(sha256 "$d/vibe-compiler-$tag.wasm")"
    printf '    "vibe-toolchain-%s.tar.gz": "%s",\n' "$tag" "$(sha256 "$d/vibe-toolchain-$tag.tar.gz")"
    printf '    "viberun-%s-%s.tar.gz": "%s"\n' "$tag" "$rtarget" "$(sha256 "$d/viberun-$tag-$rtarget.tar.gz")"
    printf '  }\n'
    printf '}\n'
  } > "$d/release-manifest.json"
}

# mk_release <version> [latest] [runner-target]
mk_release() {
  local version="$1" tag="v$1" latest="${2:-}" rtarget="${3:-$TARGET}" d stage
  d="$REL/download/$tag"
  stage="$WORK/stage-$version"
  rm -rf "$stage"
  mkdir -p "$d" "$stage/runner" "$stage/tc/bin" "$stage/tc/lib/@vibe/console"
  cat > "$stage/runner/viberun" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in --version) echo "viberun fake $version"; exit 0 ;; esac
out=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac
done
[ -n "\$out" ] || { echo "fake runner: missing -o" >&2; exit 2; }
printf 'fake-cwasm %s\n' "$version" > "\$out"
RUNNER
  chmod +x "$stage/runner/viberun"
  tar -czf "$d/viberun-$tag-$rtarget.tar.gz" -C "$stage/runner" viberun
  install -m 0755 "$ROOT_DIR/runtime/vibe" "$stage/tc/bin/vibe"
  cp "$ROOT_DIR/scripts/vibe_pkg.sh" "$ROOT_DIR/scripts/parallel_warm_pool.sh" "$stage/tc/lib/"
  cp "$ROOT_DIR/lib/@vibe/console/index.vpkg" "$stage/tc/lib/@vibe/console/"
  printf '@vibe/console\tpkg:sha1:0000000000000000000000000000000000000000\n' > "$stage/tc/stdlib-hashes.tsv"
  printf 'context pack of release %s\n' "$version" > "$stage/tc/lib/context-pack.md"
  tar -czf "$d/vibe-toolchain-$tag.tar.gz" -C "$stage/tc" bin lib stdlib-hashes.tsv
  printf 'fake-wasm %s\n' "$version" > "$d/vibe-compiler-$tag.wasm"
  write_manifest "$d" "$version" "$rtarget"
  if [ "$latest" = latest ]; then
    mkdir -p "$REL/latest/download"
    cp "$d/release-manifest.json" "$REL/latest/download/release-manifest.json"
  fi
}

mk_release 0.9.9
mk_release 1.0.0 latest

# A PATH with bash, curl, tar and the POSIX utilities the scripts use, and
# nothing that builds: no git, no cargo, no node.
lean="$WORK/lean-bin"
mkdir -p "$lean"
for cmd in bash curl tar gzip sha256sum shasum sed mkdir mv rm cp chmod uname tr cut date cat dirname basename readlink ln grep head awk mktemp env; do
  p="$(command -v "$cmd" 2>/dev/null || true)"
  [ -n "$p" ] && ln -s "$p" "$lean/$cmd"
done
for forbidden in git cargo node; do
  [ ! -e "$lean/$forbidden" ] || { echo "FAIL: $forbidden must not be on the lean PATH" >&2; exit 1; }
done

home="$WORK/home"
( cd "$WORK" && env -i PATH="$lean" HOME="$WORK/fakehome" TMPDIR="$WORK/tmp" \
    VIBE_HOME="$home" VIBE_BIN_DIR="$WORK/bin" VIBE_RELEASE_URL="$RELEASE_URL" \
    bash "$ROOT_DIR/install/install.sh" --version 0.9.9 --no-modify-path ) > "$WORK/install.log" 2>&1 && rc=0 || rc=$?
check "install.sh --version installs with bash, curl and tar" "0" "$rc"
[ "$rc" = 0 ] || sed 's/^/  | /' "$WORK/install.log" >&2
tc="$home/toolchains/0.9.9"
check "release install lays out the toolchain" "yes" "$([ -x "$tc/bin/vibe" ] && [ -x "$tc/bin/viberun" ] && [ -s "$tc/lib/vibe-cli.wasm" ] && [ -s "$tc/lib/vibe-cli.cwasm" ] && [ -f "$tc/lib/vibe_pkg.sh" ] && [ -f "$tc/lib/@vibe/console/index.vpkg" ] && [ -f "$tc/lib/context-pack.md" ] && echo yes || echo no)"
check "release install writes the manifest" "yes" "$(grep -q '"source": "release"' "$tc/manifest.json" && grep -q '"version": "0.9.9"' "$tc/manifest.json" && grep -q '"ref": "v0.9.9"' "$tc/manifest.json" && grep -q '"commit": "0123456789abcdef0123456789abcdef01234567"' "$tc/manifest.json" && echo yes || echo no)"
check "release install writes the dispatcher, env and default" "yes" "$([ -x "$home/bin/vibe" ] && [ -f "$home/env" ] && [ "$(cat "$home/toolchain")" = 0.9.9 ] && [ -L "$WORK/bin/vibe" ] && echo yes || echo no)"
check "the assets stay in the download cache" "yes" "$([ -f "$home/cache/downloads/v0.9.9/release-manifest.json" ] && [ -f "$home/cache/downloads/v0.9.9/vibe-toolchain-v0.9.9.tar.gz" ] && [ -f "$home/cache/downloads/v0.9.9/viberun-v0.9.9-$TARGET.tar.gz" ] && echo yes || echo no)"
check "no staging directory is left behind" "yes" "$([ -z "$(ls -d "$home/toolchains"/.staging-* 2>/dev/null)" ] && echo yes || echo no)"
VIBE="$home/bin/vibe"
version_line="$("$VIBE" version 2>/dev/null | sed -n '1p')"
check "vibe version reports the release" "yes" "$(printf '%s\n' "$version_line" | grep -qF 'vibe 0.9.9 (toolchain 0.9.9: release v0.9.9@0123456789ab' && echo yes || echo no)"

# self update latest -> 1.0.0, and it becomes the default.
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update latest > "$WORK/update1.log" 2>&1 && rc=0 || rc=$?
check "vibe self update latest exit" "0" "$rc"
[ "$rc" = 0 ] || sed 's/^/  | /' "$WORK/update1.log" >&2
check "self update latest resolved 1.0.0 and switched the default" "yes" "$([ -f "$home/toolchains/1.0.0/manifest.json" ] && [ "$(cat "$home/toolchain")" = 1.0.0 ] && grep -q 'latest release is 1.0.0' "$WORK/update1.log" && echo yes || echo no)"
list_out="$("$VIBE" toolchain list 2>/dev/null || true)"
check "vibe toolchain list shows both, the new one default" "yes" "$(printf '%s\n' "$list_out" | grep -qE '^\* 1\.0\.0[[:space:]]' && printf '%s\n' "$list_out" | grep -qE '^  0\.9\.9[[:space:]]' && echo yes || echo no)"

# An installed version is refused without --force; --force reinstalls.
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update 1.0.0 > "$WORK/update2.log" 2>&1 && rc=0 || rc=$?
check "self update of an installed version is refused" "yes" "$([ "$rc" != 0 ] && grep -q -- '--force' "$WORK/update2.log" && [ -f "$home/toolchains/1.0.0/manifest.json" ] && echo yes || echo no)"
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update 1.0.0 --force > "$WORK/update3.log" 2>&1 && rc=0 || rc=$?
check "self update --force reinstalls" "yes" "$([ "$rc" = 0 ] && [ -f "$home/toolchains/1.0.0/manifest.json" ] && echo yes || echo no)"

# --no-default installs without switching.
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update 0.9.9 --force --no-default > "$WORK/update4.log" 2>&1 && rc=0 || rc=$?
check "self update --no-default keeps the default" "yes" "$([ "$rc" = 0 ] && [ "$(cat "$home/toolchain")" = 1.0.0 ] && echo yes || echo no)"

# A tampered runner tarball is refused before anything is moved.
mk_release 1.0.1
printf 'tamper\n' >> "$REL/download/v1.0.1/viberun-v1.0.1-$TARGET.tar.gz"
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update 1.0.1 > "$WORK/update5.log" 2>&1 && rc=0 || rc=$?
check "a tampered runner tarball is refused" "yes" "$([ "$rc" != 0 ] && grep -q 'does not match the release manifest' "$WORK/update5.log" && echo yes || echo no)"
check "a refused update moves nothing into toolchains/" "yes" "$([ ! -e "$home/toolchains/1.0.1" ] && [ -z "$(ls -d "$home/toolchains"/.staging-* 2>/dev/null)" ] && [ "$(cat "$home/toolchain")" = 1.0.0 ] && echo yes || echo no)"
check "the mismatching download is dropped from the cache" "yes" "$([ ! -e "$home/cache/downloads/v1.0.1/viberun-v1.0.1-$TARGET.tar.gz" ] && echo yes || echo no)"

# A tampered toolchain bundle is refused by the installer's own check too.
mk_release 1.0.2
printf 'tamper\n' >> "$REL/download/v1.0.2/vibe-toolchain-v1.0.2.tar.gz"
home2="$WORK/home2"
( cd "$WORK" && env -i PATH="$lean" HOME="$WORK/fakehome" TMPDIR="$WORK/tmp" VIBE_HOME="$home2" VIBE_RELEASE_URL="$RELEASE_URL" \
    bash "$ROOT_DIR/install/install.sh" --version 1.0.2 --no-modify-path --no-link ) > "$WORK/install2.log" 2>&1 && rc=0 || rc=$?
check "install.sh refuses a tampered toolchain bundle" "yes" "$([ "$rc" != 0 ] && grep -q 'does not match the release manifest' "$WORK/install2.log" && [ ! -e "$home2/toolchains" ] && [ ! -e "$home2/bin" ] && echo yes || echo no)"

# A release with no runner for this host names the targets it ships.
mk_release 1.0.3 "" nonexistent-target
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update 1.0.3 > "$WORK/update6.log" 2>&1 && rc=0 || rc=$?
check "a release without a runner for this host is refused, naming the targets" "yes" "$([ "$rc" != 0 ] && grep -q "ships no runner for $TARGET" "$WORK/update6.log" && grep -q 'nonexistent-target' "$WORK/update6.log" && [ ! -e "$home/toolchains/1.0.3" ] && echo yes || echo no)"

# An unknown version is refused with the URL that was tried.
VIBE_RELEASE_URL="$RELEASE_URL" "$VIBE" self update 7.7.7 > "$WORK/update7.log" 2>&1 && rc=0 || rc=$?
check "an unpublished version is refused" "yes" "$([ "$rc" != 0 ] && grep -q 'is 7.7.7 a published release' "$WORK/update7.log" && echo yes || echo no)"

# A flat home is refused by release mode as well.
flat="$WORK/flat"
mkdir -p "$flat/bin" "$flat/lib"
printf 'fake\n' > "$flat/lib/vibe-cli.wasm"
( cd "$WORK" && env -i PATH="$lean" HOME="$WORK/fakehome" TMPDIR="$WORK/tmp" VIBE_HOME="$flat" VIBE_RELEASE_URL="$RELEASE_URL" \
    bash "$ROOT_DIR/install/install.sh" --version 0.9.9 --no-modify-path --no-link ) > "$WORK/install3.log" 2>&1 && rc=0 || rc=$?
check "install.sh --version refuses a flat-layout VIBE_HOME" "yes" "$([ "$rc" != 0 ] && grep -q 'flat' "$WORK/install3.log" && [ ! -e "$flat/toolchains" ] && echo yes || echo no)"

echo "[test] $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
