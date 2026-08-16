#!/usr/bin/env bash
# Network-free regression for the public curl|bash bootstrap path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

repo="$WORK/source"
mkdir -p "$repo/install" "$repo/bootstrap" "$repo/runtime" "$repo/scripts"
cp "$ROOT_DIR/install/install.sh" "$repo/install/install.sh"
cp "$ROOT_DIR/bootstrap/seed.json" "$repo/bootstrap/seed.json"
cp "$ROOT_DIR/runtime/vibe" "$repo/runtime/vibe"
cp "$ROOT_DIR/scripts/vibe_pkg.sh" "$repo/scripts/vibe_pkg.sh"
cp "$ROOT_DIR/scripts/parallel_warm_pool.sh" "$repo/scripts/parallel_warm_pool.sh"
(
  cd "$repo"
  git init -q -b curl-test
  git add .
  git -c user.name=vibe-test -c user.email=vibe-test@invalid commit -q -m fixture
)

runner="$WORK/fake-viberun"
cat > "$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || { echo "fake runner: missing -o" >&2; exit 2; }
printf 'fake-cwasm\n' > "$out"
RUNNER
chmod +x "$runner"
printf 'fake-wasm\n' > "$WORK/compiler.wasm"
mkdir -p "$WORK/outside" "$WORK/tmp"

(
  cd "$WORK/outside"
  cat "$ROOT_DIR/install/install.sh" | env \
    TMPDIR="$WORK/tmp" \
    VIBE_INSTALL_REPO="$repo" \
    VIBE_INSTALL_REF="curl-test" \
    VIBE_HOME="$WORK/home" \
    VIBE_BIN_DIR="$WORK/bin" \
    bash -s -- \
      --runner "$runner" \
      --cli-wasm "$WORK/compiler.wasm" \
      --no-stdlib \
      --no-modify-path >/dev/null
)

[ "$(cat "$WORK/home/toolchain")" = "curl-test" ]
[ -x "$WORK/home/toolchains/curl-test/bin/viberun" ]
[ -x "$WORK/home/toolchains/curl-test/bin/vibe" ]
[ -s "$WORK/home/toolchains/curl-test/lib/vibe-cli.wasm" ]
[ -s "$WORK/home/toolchains/curl-test/lib/vibe-cli.cwasm" ]
[ -L "$WORK/bin/vibe" ]
if find "$WORK/tmp" -maxdepth 1 -name 'vibe-install-*' -print -quit | grep -q .; then
  echo "curl bootstrap left a temporary checkout behind" >&2
  exit 1
fi

echo "ok: curl bootstrap cloned a local ref, installed it, and cleaned up"
