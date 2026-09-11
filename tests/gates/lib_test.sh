#!/usr/bin/env bash
# Self-test for the helpers in tests/gates/lib.sh.
#
# `gate_split_cli_cache_is_current` decides WHICH compiler the #2305 lane
# questions. It got one because the thing it replaced -- "reuse whatever is at
# _build/bench/selfhost_cli_core/index_stage1.wasm" -- produced a false RED
# twice in one session on a reused workspace, and the same mechanism produces
# a false GREEN just as easily.
set -euo pipefail

GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$GATES_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_gates_lib_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()  { echo "ok: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1" >&2; failed=$((failed + 1)); }

# Two distinct "stage2" artifacts. Content, not names: the helper compares
# bytes, so the test must too.
printf 'stage2-A' > "$WORK/a.wasm"
printf 'stage2-B' > "$WORK/b.wasm"

fresh_cache() {
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
  printf 'cli' > "$WORK/cache/index_stage1.wasm"
  cp "$1" "$WORK/cache/base_stage2.wasm"
}

# 1. built from THIS stage2 -> reuse, and the cache survives.
fresh_cache "$WORK/a.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/a.wasm"; then
  if [ -s "$WORK/cache/index_stage1.wasm" ]; then
    ok "a cache built from this stage2 is reused"
  else
    bad "answered current but removed the cache"
  fi
else
  bad "a cache built from this stage2 was rejected"
fi

# 2. built from a DIFFERENT stage2 -> refuse, and the cache is GONE. Removing
#    it is the half that matters: a caller that ignores the status still
#    cannot reuse a mismatched artifact.
fresh_cache "$WORK/b.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/a.wasm"; then
  bad "a cache built from another stage2 was accepted"
elif [ -e "$WORK/cache" ]; then
  bad "rejected a mismatched cache but left it in place"
else
  ok "a cache built from another stage2 is rejected AND removed"
fi

# 3. same SIZE, different bytes. Size and mtime are the proxies this helper
#    exists to avoid; without a content compare this case passes wrongly.
fresh_cache "$WORK/a.wasm"
printf 'stage2-C' > "$WORK/c.wasm"
if [ "$(wc -c < "$WORK/a.wasm")" != "$(wc -c < "$WORK/c.wasm")" ]; then
  bad "the same-size case is not set up: a and c differ in length"
elif gate_split_cli_cache_is_current "$WORK/cache" "$WORK/c.wasm"; then
  bad "a same-size, different-content stage2 was accepted"
else
  ok "identity is content, not size"
fi

# 4. no provenance record at all (what every pre-existing cache looks like)
#    -> refuse. Otherwise the first run after this lands trusts a directory
#    whose origin nobody knows.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
printf 'cli' > "$WORK/cache/index_stage1.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/a.wasm"; then
  bad "a cache with no provenance record was accepted"
else
  ok "a cache with no provenance record is rejected"
fi

# 5. a missing stage2 -> refuse rather than treat absence as a match.
fresh_cache "$WORK/a.wasm"
if gate_split_cli_cache_is_current "$WORK/cache" "$WORK/nonexistent.wasm"; then
  bad "a missing stage2 was treated as a match"
else
  ok "a missing stage2 is rejected"
fi

echo "----"
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
