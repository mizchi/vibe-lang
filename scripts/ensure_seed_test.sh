#!/usr/bin/env bash
# Red/Green self-test for scripts/ensure_seed.sh's rebuild fallback: when the
# pinned release does not exist, the seed is rebuilt from seed.source_commit
# and installed ONLY if it matches the pinned sha256; the opt-out keeps the
# old fail-fast. The real rebuild (a stage0->stage2 build, ~10 min) is
# replaced by VIBE_ENSURE_SEED_REBUILD_CMD, which receives the destination
# path as $1; the sha256 comparison under test is the real one.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
unset VIBE_ENSURE_SEED_NO_REBUILD VIBE_ENSURE_SEED_REBUILD_CMD

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "[ensure-seed-test] FAIL: $*" >&2; exit 1; }

sha256_of() {
  if sha256sum </dev/null >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

printf 'seed-bytes-for-the-test\n' > "$work/good.wasm"
good_sha="$(sha256_of "$work/good.wasm")"
missing_tag="seed/does-not-exist-ensure-seed-test"
write_manifest() {
  cat > "$work/seed.json" <<JSON
{"schema":1,"seed":{"name":"t","tag":"$missing_tag","source_commit":"0000000000000000000000000000000000000000","entry":"lib/@vibe/compiler/cli_support.vibe","entry_name":"cli_main","artifact":{"path":"$work/out/compiler.wasm","sha256":"$good_sha"}}}
JSON
}

# 1. Opt-out keeps fail-fast: no rebuild, the message names the tag.
write_manifest; rm -rf "$work/out"
if VIBE_ENSURE_SEED_NO_REBUILD=1 bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/1.log" 2>&1; then
  fail "opt-out: expected failure for a missing release, got success"
fi
grep -q "$missing_tag" "$work/1.log" || fail "opt-out: message does not name the missing tag: $(cat "$work/1.log")"
[ ! -e "$work/out/compiler.wasm" ] || fail "opt-out: an artifact was installed"

# 2. Green: the rebuild produces the pinned bytes -> installed and verified.
write_manifest; rm -rf "$work/out"
if ! VIBE_ENSURE_SEED_REBUILD_CMD="cp '$work/good.wasm' \"\$1\"" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/2.log" 2>&1; then
  fail "rebuild: expected success when the rebuild matches the pin: $(cat "$work/2.log")"
fi
[ "$(sha256_of "$work/out/compiler.wasm")" = "$good_sha" ] || fail "rebuild: installed artifact does not match the pin"
grep -q "installed and verified" "$work/2.log" || fail "rebuild: success line missing: $(cat "$work/2.log")"

# 3. Red: the rebuild produces other bytes -> refused, nothing left installed as verified.
write_manifest; rm -rf "$work/out"
printf 'not-the-pinned-bytes\n' > "$work/bad.wasm"
if VIBE_ENSURE_SEED_REBUILD_CMD="cp '$work/bad.wasm' \"\$1\"" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/3.log" 2>&1; then
  fail "rebuild: a rebuild that does not match the pin was accepted"
fi
grep -q "does not match the pin" "$work/3.log" || fail "rebuild: mismatch message missing: $(cat "$work/3.log")"

echo "[ensure-seed-test] ok (opt-out fails fast, matching rebuild installs, mismatching rebuild is refused)"
