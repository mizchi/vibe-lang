#!/usr/bin/env bash
# Manifest-header cache coverage (#cov): the corpus's only manifest-rooted entry
# is the compiler itself, whose cold FS-compile traps before it can populate the
# persistent manifest-header cache — so the cache-VALIDATION cluster
# (matches_cached_file_spec, load_persistent_manifest_header_cache_if_valid,
# collect_needed_paths_from_manifest_headers, bind_import_names_from_cache,
# try_collect_manifest_source_groups_fs, append_import_alias_collision_defs_*)
# never runs. Here we stand up a tiny standalone manifest project that
# FS-compiles cleanly, then drive cold/warm/partial-invalidation/source-mutation
# permutations so each cache-state branch is taken, unioning into the corpus
# acc.json. Reuses the instrumented compiler_cov.wasm built by the corpus run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
OUT="_build/coverage/selfhost-corpus"
COMP="$OUT/compiler_cov.wasm"
ACC="$OUT/acc.json"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
RUN_JSON="$OUT/mc_run.json"
[ -s "$COMP" ] || { echo "manifestcache: instrumented compiler not found; run corpus first" >&2; exit 1; }
[ -s "$ACC" ] || { echo "manifestcache: corpus acc not found" >&2; exit 1; }

P="_build/covproj"; rm -rf "$P"; mkdir -p "$P"
cat > "$P/a.vibe" <<'EOF'
export let a_val: () -> Int = () -> { 41 }
export let a_two: () -> Int = () -> { 2 }
EOF
cat > "$P/b.vibe" <<'EOF'
import ./a.vibe { a_val, a_two as a_dup }
export let b_val: () -> Int = () -> { a_val() + a_dup() }
EOF
cat > "$P/c.vibe" <<'EOF'
import ./a.vibe { a_two }
export let c_val: () -> Int = () -> { a_two() * 10 }
EOF
cat > "$P/main.vibe" <<'EOF'
import ./b.vibe { b_val }
import ./c.vibe { c_val }
export let main: () -> Int = () -> { b_val() + c_val() }
EOF
printf '# group\tpath\n' > "$P/selfhost_sources_manifest.tsv"
for m in a b c main; do printf 'grp\t%s.vibe\n' "$m" >> "$P/selfhost_sources_manifest.tsv"; done

acc_run() {
  rm -f "$RUN_JSON"
  VIBE_COV_OUT="$RUN_JSON" VIBE_COV_RAW=1 VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_PREOPEN_DIR="$ROOT" bash "$RUNNER" --invoke cli_main "$COMP" "$P/main.vibe" "$P/out.wasm" main >/dev/null 2>&1 || true
  [ -s "$RUN_JSON" ] && python3 "$OUT/acc_merge.py" "$ACC" "$RUN_JSON" || true
}
base=$(python3 -c "import json;a=json.load(open('$ACC'));print(sum(a['br']))")

rm -f _build/vibe_selfhost_* 2>/dev/null || true
acc_run                                                        # 1. cold: writes all caches
acc_run                                                        # 2. fully warm: all cache hits
# 3. drop source-groups + source-list caches, KEEP manifest-header cache ->
#    collect_source_groups_fs falls through to try_collect_manifest_source_groups_fs
#    which loads the WARM header cache (matches_cached_file_spec validates each row).
rm -f _build/vibe_selfhost_source_groups_* 2>/dev/null || true
acc_run
# 4. mutate a leaf source so its fingerprint no longer matches the cached spec
#    (matches_cached_file_spec false branch / cache-invalidation path).
rm -f _build/vibe_selfhost_source_groups_* 2>/dev/null || true
printf '\nexport let a_extra: () -> Int = () -> { 7 }\n' >> "$P/a.vibe"
acc_run
# 5. drop only the manifest-header cache, keep dep/header caches -> rebuild header
#    rows fresh (collect_needed_paths_and_manifest_headers + store path).
rm -f _build/vibe_selfhost_manifest_headers_* _build/vibe_selfhost_source_groups_* 2>/dev/null || true
acc_run
# 6. warm again after the rebuild (header cache hit on the mutated tree).
rm -f _build/vibe_selfhost_source_groups_* 2>/dev/null || true
acc_run
# 7. drop type-env caches -> recheck with warm source/dep caches.
rm -f _build/vibe_selfhost_type_env_* _build/vibe_selfhost_source_groups_* 2>/dev/null || true
acc_run
rm -f _build/vibe_selfhost_* 2>/dev/null || true

now=$(python3 -c "import json;a=json.load(open('$ACC'));print(sum(a['br']))")
tot=$(python3 -c "import json;a=json.load(open('$ACC'));print(len(a['br']))")
echo "[manifestcache] corpus branches: $base -> $now/$tot ($(python3 -c "print(f'{$now/$tot*100:.2f}')")%)  (+$((now-base)))"
