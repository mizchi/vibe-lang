#!/usr/bin/env bash
# Red/green for scripts/build_release_assets.sh's publication contract (#2248: a
# guard means nothing until it is shown to fail, and nothing good until it is
# shown not to fail on what it must let through).
#
# Argument handling and product artifact selection are exercised with distinct
# bootstrap and current-compiler outputs. The real compiler build is replaced
# in the scratch tree, so the packaging contract needs no bootstrap build.
#
#   $ bash scripts/build_release_assets.sh v0.1.0-rc.0
#   release-assets: invalid semver: 0.1.0-rc.0
#
# The grammar was `^[0-9]+\.[0-9]+\.[0-9]+$`, so EVERY pre-release tag died on
# release.yml's first job. `scripts/check_version_ladder.sh` had accepted the
# same spelling all along, so the tree held two different definitions of "a
# version" and nothing read them against each other.
#
# The version-agreement arm is checked against a scratch launcher rather than
# the real one, so these cases keep saying the same thing after the tree's own
# version moves on.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-release-assets-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then note "  ok   $1"
  else note "  FAIL $1: got '$2' want '$3'"; fail=1; fi
}
says() {
  if printf '%s' "$1" | grep -qF "$2"; then note "  ok   says: $2"
  else note "  FAIL did not say: $2"; printf '%s\n' "$1" | sed 's/^/      /' | head -5; fail=1; fi
}
silent_about() {
  if printf '%s' "$1" | grep -qF "$2"; then note "  FAIL unexpectedly said: $2"; fail=1
  else note "  ok   free of: $2"; fi
}

# A scratch PROJECT_ROOT: the script resolves it from its own location, so the
# copy under $WORK/t/scripts reads $WORK/t/runtime/vibe.
setup() { # setup <launcher version>
  rm -rf "$WORK/t"
  mkdir -p "$WORK/t/scripts" "$WORK/t/runtime"
  cp "$ROOT_DIR/scripts/build_release_assets.sh" "$WORK/t/scripts/"
  printf 'set -euo pipefail\nVIBE_VERSION="%s"\n' "$1" > "$WORK/t/runtime/vibe"
}

run() { # run <tag> -> OUT, RC. Times out: past validation it would really build.
  OUT="$(run_bounded 25 bash "$WORK/t/scripts/build_release_assets.sh" "$1" 2>&1)"
  RC=$?
}

note "=== 1. green: a pre-release tag passes the grammar (the #2248 defect) ==="
setup "0.1.0-rc.0"; run v0.1.0-rc.0
silent_about "$OUT" "invalid semver"
silent_about "$OUT" "VIBE_VERSION mismatch"

note "=== 2. green: the plain release tag still passes ==="
setup "0.1.0"; run v0.1.0
silent_about "$OUT" "invalid semver"
silent_about "$OUT" "VIBE_VERSION mismatch"

note "=== 3. green: build metadata passes ==="
setup "0.1.0+build7"; run v0.1.0+build7
silent_about "$OUT" "invalid semver"

note "=== 4. green: the tag may be given without the leading v ==="
setup "0.1.0-rc.0"; run 0.1.0-rc.0
silent_about "$OUT" "invalid semver"
silent_about "$OUT" "VIBE_VERSION mismatch"

note "=== 5. red: a tag that is not a version at all ==="
setup "0.1.0"; run vnope
check "exit" "$RC" "1"
says "$OUT" "invalid semver: nope"

note "=== 6. red: a version-shaped tag with a junk pre-release ==="
# `+` is not a legal pre-release character; it opens build metadata, so
# `1.0.0-rc+` has an empty metadata field and must not be accepted.
setup "0.1.0"; run "v1.0.0-rc+"
check "exit" "$RC" "1"
says "$OUT" "invalid semver"

note "=== 7. red: the launcher and the tag disagree ==="
# The guard that stops a release shipping a version it does not report. An rc
# tree must not be publishable under the release's own number.
setup "0.1.0-rc.0"; run v0.1.0
check "exit" "$RC" "1"
says "$OUT" "VIBE_VERSION mismatch"
says "$OUT" "got=0.1.0-rc.0"

note "=== 8. red: and the reverse -- a release tree tagged as a candidate ==="
setup "0.1.0"; run v0.1.0-rc.0
check "exit" "$RC" "1"
says "$OUT" "VIBE_VERSION mismatch"

note "=== 9. a product install selects the current compiler, preserving the seed ==="
setup "0.1.0-rc.3"
cat > "$WORK/t/scripts/build_compiler_seed_assets.sh" <<'SH'
set -eu
tag="$1"; out="$2"
printf 'bootstrap compiler\n' > "$out/vibe-compiler-$tag.wasm"
printf 'current source\n' > "$out/vibe-compiler-module-source-$tag.vibe"
printf '{}\n' > "$out/vibe-compiler-seed-$tag.json"
printf '{"compiler_wasm":"vibe-compiler-%s.wasm","source_commit":"seed-commit"}\n' "$tag" > "$out/.compiler-manifest-fragment.json"
SH
cat > "$WORK/t/scripts/build_cli_wasm.sh" <<'SH'
set -eu
printf 'current compiler\n' > "$1"
printf '%s\n' "$1"
SH
printf 'printf "context pack\\n"\n' > "$WORK/t/scripts/gen_context_pack.sh"
cat > "$WORK/t/scripts/run_wasm_vibe_host_runner.sh" <<'SH'
set -eu
[ "$(cat "$3")" = "current compiler" ]
printf 'package test-hash\n' > "$5"
SH
for script in vibe_pkg.sh parallel_warm_pool.sh run_bounded.sh; do
  : > "$WORK/t/scripts/$script"
done
cat > "$WORK/t/scripts/build_taskgroup_checker.sh" <<'SH'
set -eu
mkdir -p "$2"
printf 'worker\n' > "$2/worker.wasm"
printf 'coordinator\n' > "$2/coordinator.component.wasm"
printf '{}\n' > "$2/build.json"
SH
for helper in taskgroup_build_frontend.mjs taskgroup_frontend_warm.mjs taskgroup_job_cache.mjs parallel_project_transport.mjs parallel_scheduler_trace.mjs parallel_selfhost_checker.mjs; do
  : > "$WORK/t/scripts/$helper"
done
for pkg in core ast parser builtin console wit_runtime concurrent concurrent/experimental; do
  mkdir -p "$WORK/t/lib/@vibe/$pkg"
  : > "$WORK/t/lib/@vibe/$pkg/index.vpkg"
done
mkdir -p "$WORK/t/runtime/viberun"
printf 'wasmtime = { version = "47.0.2" }\n' > "$WORK/t/runtime/viberun/Cargo.toml"
run v0.1.0-rc.3
check "packaging exit" "$RC" "0"
if ! python3 - "$WORK/t/dist/release/v0.1.0-rc.3" <<'PY'
import hashlib, json, pathlib, sys, tarfile
out = pathlib.Path(sys.argv[1])
manifest = json.loads((out / 'release-manifest.json').read_text())
cli = manifest['compiler_wasm']
seed = manifest['compiler']['compiler_wasm']
assert cli != seed, (cli, seed)
assert (out / cli).read_bytes() == b'current compiler\n'
assert (out / seed).read_bytes() == b'bootstrap compiler\n'
for name in (cli, seed):
    sha = hashlib.sha256((out / name).read_bytes()).hexdigest()
    assert manifest['assets'][name] == sha, name
    assert name in manifest['artifacts'], name
    assert f'{sha}  {name}' in (out / 'SHA256SUMS.txt').read_text(), name
with tarfile.open(out / 'vibe-toolchain-v0.1.0-rc.3.tar.gz') as archive:
    names = set(archive.getnames())
    for name in ['worker.wasm', 'coordinator.component.wasm', 'build.json',
                 'taskgroup_build_frontend.mjs', 'taskgroup_frontend_warm.mjs', 'taskgroup_job_cache.mjs',
                 'parallel_project_transport.mjs', 'parallel_scheduler_trace.mjs', 'parallel_selfhost_checker.mjs']:
        assert 'lib/checker-taskgroup/' + name in names, name
PY
then
  note "  FAIL product compiler selection or checksums"
  fail=1
else
  note "  ok   current compiler selected; both compiler assets hashed"
fi

note "=== 10. a failed current compiler build refuses publication ==="
printf 'exit 1\n' > "$WORK/t/scripts/build_cli_wasm.sh"
run v0.1.0-rc.3
check "failed build exit" "$RC" "1"
if [ -f "$WORK/t/dist/release/v0.1.0-rc.3/release-manifest.json" ]; then
  note "  FAIL published a manifest after the current compiler build failed"; fail=1
else
  note "  ok   no release manifest produced"
fi

note "=== 11. a missing current compiler output refuses publication ==="
printf 'exit 0\n' > "$WORK/t/scripts/build_cli_wasm.sh"
run v0.1.0-rc.3
check "missing output exit" "$RC" "1"

note
if [ "$fail" = 0 ]; then note "[build-release-assets-test] ok"; else note "[build-release-assets-test] FAIL"; fi
exit "$fail"
