#!/usr/bin/env bash
# Red/Green self-test for scripts/ensure_seed.sh's rebuild fallback: when the
# pinned release does not exist (HTTP 404 on its manifest asset), the seed is
# rebuilt from seed.source_commit and installed ONLY if it matches the pinned
# sha256; a release that exists but cannot be fetched stays fatal; the
# opt-out keeps the old fail-fast. No network: a fake `curl` on PATH answers
# the status probe with $FAKE_CURL_STATUS and fails every download. The real
# rebuild (a stage0->stage2 build, ~10 min) is replaced by
# VIBE_ENSURE_SEED_REBUILD_CMD, which receives the destination path as $1;
# the sha256 comparison under test is the real one.
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

# Fake curl: `-w` (the status probe) prints FAKE_CURL_STATUS; any download
# attempt fails like an unreachable asset (exit 22).
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "-w" ]; then printf '%s' "${FAKE_CURL_STATUS:-000}"; exit 0; fi
done
exit 22
FAKE
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
command -v curl | grep -q "$work/bin/curl" || fail "fake curl is not first on PATH"

printf 'seed-bytes-for-the-test\n' > "$work/good.wasm"
good_sha="$(sha256_of "$work/good.wasm")"
missing_tag="seed/does-not-exist-ensure-seed-test"
write_manifest() {
  cat > "$work/seed.json" <<JSON
{"schema":1,"seed":{"name":"t","tag":"$missing_tag","source_commit":"0000000000000000000000000000000000000000","entry":"lib/@vibe/compiler/cli_support.vibe","entry_name":"cli_main","artifact":{"path":"$work/out/compiler.wasm","sha256":"$good_sha"}}}
JSON
}
rebuild_good="cp '$work/good.wasm' \"\$1\""

# 1. Opt-out keeps fail-fast on a missing release: no rebuild, the message names the tag.
write_manifest; rm -rf "$work/out"
if FAKE_CURL_STATUS=404 VIBE_ENSURE_SEED_NO_REBUILD=1 VIBE_ENSURE_SEED_REBUILD_CMD="$rebuild_good" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/1.log" 2>&1; then
  fail "opt-out: expected failure for a missing release, got success"
fi
grep -q "$missing_tag" "$work/1.log" || fail "opt-out: message does not name the missing tag: $(cat "$work/1.log")"
[ ! -e "$work/out/compiler.wasm" ] || fail "opt-out: an artifact was installed"

# 2. Green: 404 -> the rebuild produces the pinned bytes -> installed and verified.
write_manifest; rm -rf "$work/out"
if ! FAKE_CURL_STATUS=404 VIBE_ENSURE_SEED_REBUILD_CMD="$rebuild_good" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/2.log" 2>&1; then
  fail "rebuild: expected success when the rebuild matches the pin: $(cat "$work/2.log")"
fi
[ "$(sha256_of "$work/out/compiler.wasm")" = "$good_sha" ] || fail "rebuild: installed artifact does not match the pin"
grep -q "installed and verified" "$work/2.log" || fail "rebuild: success line missing: $(cat "$work/2.log")"

# 3. Red: 404 -> the rebuild produces other bytes -> refused.
write_manifest; rm -rf "$work/out"
printf 'not-the-pinned-bytes\n' > "$work/bad.wasm"
if FAKE_CURL_STATUS=404 VIBE_ENSURE_SEED_REBUILD_CMD="cp '$work/bad.wasm' \"\$1\"" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/3.log" 2>&1; then
  fail "rebuild: a rebuild that does not match the pin was accepted"
fi
grep -q "does not match the pin" "$work/3.log" || fail "rebuild: mismatch message missing: $(cat "$work/3.log")"

# 4. Red: the release EXISTS (probe 200) but its download fails -> fatal, and
#    the rebuild hook must not run even though it could have produced the pin.
write_manifest; rm -rf "$work/out"
if FAKE_CURL_STATUS=200 VIBE_ENSURE_SEED_REBUILD_CMD="$rebuild_good" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/4.log" 2>&1; then
  fail "published-but-broken: expected failure, got success"
fi
grep -q "only a release that does not exist (404) is rebuilt" "$work/4.log" || fail "published-but-broken: fatal message missing: $(cat "$work/4.log")"
[ ! -e "$work/out/compiler.wasm" ] || fail "published-but-broken: the rebuild hook installed an artifact"

# 5. Red: offline (probe 000) -> fatal, no rebuild.
write_manifest; rm -rf "$work/out"
if FAKE_CURL_STATUS=000 VIBE_ENSURE_SEED_REBUILD_CMD="$rebuild_good" bash scripts/ensure_seed.sh --manifest "$work/seed.json" >"$work/5.log" 2>&1; then
  fail "offline: expected failure, got success"
fi
[ ! -e "$work/out/compiler.wasm" ] || fail "offline: the rebuild hook installed an artifact"

echo "[ensure-seed-test] ok (404 opt-out fails fast, 404 matching rebuild installs, 404 mismatching rebuild refused, published-but-broken fatal without rebuild, offline fatal without rebuild)"
