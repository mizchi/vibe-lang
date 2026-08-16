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
commit_sha="$(git -C "$repo" rev-parse HEAD)"

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

assert_no_bootstrap_temp() {
  if find "$WORK/tmp" -maxdepth 1 -name 'vibe-install-*' -print -quit | grep -q .; then
    echo "curl bootstrap left a temporary checkout behind" >&2
    exit 1
  fi
}

run_from_stdin() {
  local home="$1"
  local bin="$2"
  shift 2
  (
    cd "$WORK/outside"
    cat "$ROOT_DIR/install/install.sh" | env \
      TMPDIR="$WORK/tmp" \
      VIBE_INSTALL_REPO="$WORK/environment-repo-must-not-win" \
      VIBE_INSTALL_REF="environment-ref-must-not-win" \
      VIBE_HOME="$home" \
      VIBE_BIN_DIR="$bin" \
      bash -s -- \
        --repo "$repo" \
        "$@" \
        --runner "$runner" \
        --cli-wasm "$WORK/compiler.wasm" \
        --no-stdlib \
        --no-modify-path >/dev/null
  )
}

# CLI --repo/--ref override conflicting environment values. A hostile prefix
# remains path data when the generated env file is sourced.
home="$WORK/home ' \$(touch injected)"
run_from_stdin "$home" "$WORK/bin" --ref curl-test --toolchain explicit-toolchain
[ "$(cat "$home/toolchain")" = "explicit-toolchain" ]
[ -x "$home/toolchains/explicit-toolchain/bin/viberun" ]
[ -x "$home/toolchains/explicit-toolchain/bin/vibe" ]
[ -s "$home/toolchains/explicit-toolchain/lib/vibe-cli.wasm" ]
[ -s "$home/toolchains/explicit-toolchain/lib/vibe-cli.cwasm" ]
[ -L "$WORK/bin/vibe" ]
(
  cd "$WORK"
  PATH=/usr/bin:/bin /bin/sh -c '. "$1"; [ "${PATH%%:*}" = "$2" ]' \
    sh "$home/env" "$home/bin"
)
[ ! -e "$WORK/injected" ] || { echo "generated env executed prefix contents" >&2; exit 1; }
assert_no_bootstrap_temp

# Exact commit IDs are valid bootstrap refs and become safe default toolchain
# names when no explicit --toolchain is supplied.
sha_home="$WORK/sha-home"
run_from_stdin "$sha_home" "$WORK/sha-bin" --ref "$commit_sha"
[ "$(cat "$sha_home/toolchain")" = "$commit_sha" ]
[ -x "$sha_home/toolchains/$commit_sha/bin/vibe" ]
assert_no_bootstrap_temp

# Explicit toolchain names are single safe path components. Reject traversal,
# dot components, whitespace, separators, and empty values before any writes.
for bad in '' . .. ../escape name/part 'bad name'; do
  bad_home="$WORK/rejected-home"
  rm -rf "$bad_home"
  if VIBE_HOME="$bad_home" bash "$repo/install/install.sh" --__vibe-install-root "$repo" \
      --toolchain "$bad" \
      --runner "$runner" \
      --cli-wasm "$WORK/compiler.wasm" \
      --no-stdlib --no-modify-path >/dev/null 2>&1; then
    echo "unsafe toolchain name was accepted: '$bad'" >&2
    exit 1
  fi
  [ ! -e "$bad_home" ]
done

# The installed dispatcher applies the same validation to VIBE_TOOLCHAIN.
if VIBE_HOME="$home" VIBE_TOOLCHAIN=../escape "$home/bin/vibe" >/dev/null 2>&1; then
  echo "dispatcher accepted a traversing VIBE_TOOLCHAIN" >&2
  exit 1
fi

# Failed fetches clean the temporary checkout just like successful installs.
if (
  cd "$WORK/outside"
  cat "$ROOT_DIR/install/install.sh" | env TMPDIR="$WORK/tmp" \
    bash -s -- --repo "$repo" --ref definitely-missing >/dev/null 2>&1
); then
  echo "bootstrap unexpectedly fetched a missing ref" >&2
  exit 1
fi
assert_no_bootstrap_temp

echo "ok: curl bootstrap pins refs, separates CLI options, rejects unsafe authority, and cleans up"
