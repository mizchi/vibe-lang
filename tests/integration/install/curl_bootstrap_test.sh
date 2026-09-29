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
cp "$ROOT_DIR/scripts/run_bounded.sh" "$repo/scripts/run_bounded.sh"
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

# Default compiler acquisition needs Node because the seed wasm is a
# gitignored fetched/build artifact. Fail before creating VIBE_HOME, while an
# explicit compiler wasm keeps the supported Node-free installation path.
node_less_bin="$WORK/node-less-bin"
mkdir -p "$node_less_bin"
for cmd in bash mkdir install chmod cat sed; do
  ln -s "$(command -v "$cmd")" "$node_less_bin/$cmd"
done
node_error="$WORK/node-required.err"
if PATH="$node_less_bin" VIBE_HOME="$WORK/node-required-home" \
    /bin/bash "$repo/install/install.sh" --__vibe-install-root "$repo" \
      --runner "$runner" --no-stdlib --no-modify-path --no-link \
      >/dev/null 2>"$node_error"; then
  echo "default install unexpectedly succeeded without Node" >&2
  exit 1
fi
grep -q 'Node.js is required.*--cli-wasm PATH' "$node_error"
[ ! -e "$WORK/node-required-home" ] || {
  echo "Node requirement was not checked before installation writes" >&2
  exit 1
}
PATH="$node_less_bin" VIBE_HOME="$WORK/node-free-home" \
  /bin/bash "$repo/install/install.sh" --__vibe-install-root "$repo" \
    --toolchain node-free --runner "$runner" \
    --cli-wasm "$WORK/compiler.wasm" \
    --no-stdlib --no-modify-path --no-link >/dev/null
[ -x "$WORK/node-free-home/toolchains/node-free/bin/vibe" ]

# A checkout may retain a runnable target/release/viberun from before a new
# compiler import was added. The default install must refresh that binary;
# --runner above remains the explicit way to supply one without Cargo.
prebuilt="$repo/runtime/viberun/target/release/viberun"
mkdir -p "$(dirname "$prebuilt")"
cp "$runner" "$prebuilt"
printf '# stale runner\n' >> "$prebuilt"
mkdir -p "$repo/runtime/viberun/src" "$WORK/fake-cargo-bin"
printf 'fn main() {}\n' > "$repo/runtime/viberun/src/main.rs"
printf '[package]\nname = "viberun"\nversion = "0.0.0"\n' > "$repo/runtime/viberun/Cargo.toml"
cat > "$WORK/fake-cargo-bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -euo pipefail
action="$1"
shift
root=""
locked=0
target_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --target-dir) target_dir="$2"; shift 2 ;;
    --locked) locked=1; shift ;;
    *) shift ;;
  esac
done
case "$action" in
  install)
    [ "$locked" = 1 ] && [ -n "$root" ] && [ "$target_dir" = "$root/target" ] || exit 2
    mkdir -p "$root/bin"
    cp "$VIBE_TEST_FRESH_RUNNER" "$root/bin/viberun"
    printf 'called\n' > "$VIBE_TEST_CARGO_INSTALL_CALLED"
    ;;
  *) echo "fake cargo: unexpected action $action" >&2; exit 2 ;;
esac
CARGO
chmod +x "$WORK/fake-cargo-bin/cargo"
PATH="$WORK/fake-cargo-bin:$PATH" CARGO_TARGET_DIR="$WORK/external-target" \
  CARGO_BUILD_TARGET=configured-target \
  RUSTC="$WORK/compiler-selected-by-cargo" \
  VIBE_TEST_CARGO_INSTALL_CALLED="$WORK/cargo-install-called" \
  VIBE_TEST_FRESH_RUNNER="$runner" VIBE_HOME="$WORK/fresh-runner-home" \
  bash "$repo/install/install.sh" --__vibe-install-root "$repo" \
    --toolchain fresh-runner --cli-wasm "$WORK/compiler.wasm" \
    --no-stdlib --no-modify-path --no-link >/dev/null
cmp "$runner" "$WORK/fresh-runner-home/toolchains/fresh-runner/bin/viberun" || {
  echo "checkout install shipped the stale runner with Cargo target overrides" >&2
  exit 1
}
[ -s "$WORK/cargo-install-called" ] || {
  echo "checkout install did not install the runner through Cargo" >&2
  exit 1
}
for staged in "$WORK/fresh-runner-home/toolchains/fresh-runner"/.runner-stage.*; do
  [ ! -e "$staged" ] || { echo "checkout install left its runner staging directory" >&2; exit 1; }
done

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

echo "ok: curl bootstrap pins refs, refreshes the checkout runner, separates CLI options, rejects unsafe authority, and cleans up"
