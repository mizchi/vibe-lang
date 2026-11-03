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

# Selection runs in an isolated real git checkout. Its build stand-ins copy
# source bytes through the generated flat input, so reusing either a stale
# generation or a stale fallback produces the wrong artifact, not just a
# missing marker. No fake generation enters the working checkout.
selection_repo="$WORK/selection"
mkdir -p "$selection_repo/scripts" "$selection_repo/lib/@vibe/compiler"
git -C "$selection_repo" init --quiet
git -C "$selection_repo" config user.name vibe
git -C "$selection_repo" config user.email vibe@example.invalid
printf 'current source A' > "$selection_repo/source.vibe"
git -C "$selection_repo" add source.vibe
git -C "$selection_repo" commit --quiet -m init
cp "$ROOT_DIR/scripts/run_bounded.sh" "$ROOT_DIR/scripts/resolve_stage2.sh" "$selection_repo/scripts/"
cat > "$selection_repo/scripts/ensure_generated.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ ! -f fail-freshen ] || exit 8
cp source.vibe lib/@vibe/compiler/_cli_adapter_module_source.vibe
EOF
cat > "$selection_repo/scripts/generations.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$*" = 'build --out-dir _build/_gate_lane_gen' ]
[ "$VIBE_PREBUILT_MODULE_SOURCE" = 'lib/@vibe/compiler/_cli_adapter_module_source.vibe' ]
[ ! -f fail-build ] || exit 7
mkdir -p _build/_gate_lane_gen
if [ -f empty-build ]; then : > _build/_gate_lane_gen/stage2.wasm; exit 0; fi
cp "$VIBE_PREBUILT_MODULE_SOURCE" _build/_gate_lane_gen/stage2.wasm
printf 'build\n' >> builds
EOF
selection_sha="$(git -C "$selection_repo" rev-parse --short HEAD)"
head_gen="$selection_repo/_build/selfhost/generations/seed_$selection_sha"
stale_gen="$selection_repo/_build/selfhost/generations/seed_deadbee"
mkdir -p "$head_gen" "$stale_gen"
printf 'current HEAD compiler' > "$head_gen/stage2.wasm"
printf 'stale compiler' > "$stale_gen/stage2.wasm"
touch -t 203001010000 "$stale_gen"
[ "$stale_gen" -nt "$head_gen" ] || { echo 'FAIL: newer stale-generation mutation did not land' >&2; exit 1; }
select_compiler() {
  ROOT_DIR="$selection_repo" SCRIPT_DIR="$selection_repo/scripts" VIBE_STAGE2_WASM="${1:-}" \
    bash -c '. "$1"; gate_resolve_stage2; [ "$stage2_wasm" = "$VIBE_STAGE2_WASM" ] || exit 91; cat "$stage2_wasm"' \
    _ "$GATES_DIR/lib.sh"
}
if [ "$(select_compiler)" = 'current HEAD compiler' ]; then
  ok "HEAD's generation wins over a newer stale generation and is exported"
else
  bad "a newer stale generation hijacks the compiler selection"
fi
printf 'explicit compiler' > "$WORK/explicit.wasm"
if [ "$(select_compiler "$WORK/explicit.wasm")" = 'explicit compiler' ]; then
  ok "an explicit compiler wins over the HEAD generation and is exported"
else
  bad "an explicit compiler was ignored"
fi
if select_compiler "$WORK/missing.wasm" > "$WORK/missing.out" 2>&1; then
  bad "a missing explicit compiler silently falls back"
else
  ok "a missing explicit compiler is refused"
fi
rm -rf "$head_gen"
mkdir -p "$selection_repo/_build/_gate_lane_gen"
printf 'stale fallback' > "$selection_repo/_build/_gate_lane_gen/stage2.wasm"
if select_compiler > "$WORK/build.out" && cmp -s "$selection_repo/source.vibe" "$selection_repo/_build/_gate_lane_gen/stage2.wasm"; then
  ok "without HEAD's generation, current sources build instead of reusing stale artifacts"
else
  bad "a stale generation or fallback was reused instead of building current sources"
fi
rm -rf "$stale_gen"
printf 'current source B' > "$selection_repo/source.vibe"
if select_compiler > "$WORK/rebuild.out" && cmp -s "$selection_repo/source.vibe" "$selection_repo/_build/_gate_lane_gen/stage2.wasm" && [ "$(wc -l < "$selection_repo/builds" | tr -d ' ')" = 2 ]; then
  ok "a later invocation rebuilds an unproven fallback from changed sources"
else
  bad "an existing fallback masks changed sources"
fi
printf 'current source C' > "$selection_repo/source.vibe"
: > "$selection_repo/fail-build"
if select_compiler > "$WORK/failed-build.out" 2>&1; then
  bad "a failed build returns the old fallback artifact"
else
  ok "a failed build refuses even when an old fallback remains"
fi
rm "$selection_repo/fail-build"
printf 'current source D' > "$selection_repo/source.vibe"
: > "$selection_repo/fail-freshen"
if select_compiler > "$WORK/failed-freshen.out" 2>&1; then
  bad "failed source regeneration still builds from stale flat input"
else
  ok "failed source regeneration is refused"
fi
rm "$selection_repo/fail-freshen"
: > "$selection_repo/empty-build"
if select_compiler > "$WORK/empty-build.out" 2>&1; then
  bad "a successful build can return an empty artifact"
else
  ok "an empty build product is refused"
fi

echo "----"
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
