#!/usr/bin/env bash
# Multi-module FS-compile coverage (#cov): the in-memory module merge
# (build_merged_source) and FS import path namespace private values, resolve
# aliased imports, and handle alias collisions — arms a single-file compile never
# reaches. Stand up a small manifest project whose non-entry modules carry private
# lets/enums/structs/type-aliases AND whose entry imports the SAME exported name
# from two modules under different aliases (the collision case), then FS-compile it
# (cold+warm) under the instrumented compiler, unioning into the corpus acc.json.
# Reuses compiler_cov.wasm built by coverage_corpus.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
OUT="_build/coverage/selfhost-corpus"
COMP="$OUT/compiler_cov.wasm"
ACC="$OUT/acc.json"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
RUN_JSON="$OUT/mm_run.json"
[ -s "$COMP" ] || { echo "multimodule: instrumented compiler not found; run corpus first" >&2; exit 1; }
[ -s "$ACC" ] || { echo "multimodule: corpus acc not found" >&2; exit 1; }

P="_build/covrich"; rm -rf "$P"; mkdir -p "$P"
cat > "$P/m_a.vibe" <<'EOF'
let helper: () -> Int = () -> { 1 }
enum AStatus { AOk; AErr(Int) }
let a_status_code: (AStatus) -> Int = (s) -> { match s { AOk => 0, AErr(n) => n } }
export let answer: () -> Int = () -> { helper() + a_status_code(AOk) }
export let a_extra: () -> Int = () -> { helper() * 2 }
EOF
cat > "$P/m_b.vibe" <<'EOF'
let helper: () -> Int = () -> { 2 }
struct BPair { lo: Int; hi: Int }
type BNum = Int
let b_sum: (BPair) -> BNum = (p) -> { p.lo + p.hi }
export let answer: () -> Int = () -> { helper() + b_sum(BPair::{ lo: 1, hi: 2 }) }
EOF
cat > "$P/m_common.vibe" <<'EOF'
let secret: () -> Int = () -> { 100 }
export let common_val: () -> Int = () -> { secret() }
EOF
cat > "$P/main.vibe" <<'EOF'
import ./m_a.vibe { answer as answer_a, a_extra }
import ./m_b.vibe { answer as answer_b }
import ./m_common.vibe { common_val }
export let main: () -> Int = () -> { answer_a() + answer_b() + a_extra() + common_val() }
EOF
printf '# group\tpath\n' > "$P/selfhost_sources_manifest.tsv"
for m in m_a m_b m_common main; do printf 'grp\t%s.vibe\n' "$m" >> "$P/selfhost_sources_manifest.tsv"; done

run() {
  rm -f "$RUN_JSON"
  VIBE_COV_OUT="$RUN_JSON" VIBE_COV_RAW=1 VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    VIBE_PREOPEN_DIR="$ROOT" bash "$RUNNER" --invoke cli_main "$COMP" "$P/main.vibe" "$P/out.wasm" main >/dev/null 2>&1 || true
  [ -s "$RUN_JSON" ] && python3 "$OUT/acc_merge.py" "$ACC" "$RUN_JSON" || true
}
base=$(python3 -c "import json;print(sum(json.load(open('$ACC'))['br']))")
rm -f _build/vibe_selfhost_* 2>/dev/null || true
run                                                    # cold: build + write caches
run                                                    # warm: cache hits
rm -f _build/vibe_selfhost_source_groups_* 2>/dev/null || true
run                                                    # source-groups miss, header cache warm
rm -f _build/vibe_selfhost_* 2>/dev/null || true
now=$(python3 -c "import json;print(sum(json.load(open('$ACC'))['br']))")
tot=$(python3 -c "import json;print(len(json.load(open('$ACC'))['br']))")
echo "[multimodule] corpus branches: $base -> $now/$tot ($(python3 -c "print(f'{$now/$tot*100:.2f}')")%)  (+$((now-base)))"
