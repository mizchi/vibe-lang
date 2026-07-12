# Selfhost compile speed / memory profile — 2026-07-12

`Profiler::heap_bytes` 追加 (#このPR) の背景となる計測記録。手順は
`.claude/skills/compiler-perf-profiling` (今回 §0 のワンコマンド
`scripts/profile_selfhost_compile.sh` を追加)。

## 対象

- stage2 (selfhost_generations build, seed = 2026-06 系) が
  `lib/@vibe/compiler/tests/codegen_lexer_test.vibe` (compiler closure を丸ごと
  compile する重量級) を 1 回コンパイル。
- node runner (`scripts/wasm_vibe_host_runner.js`), raw ABI, linear backend。

## CPU (self-time, node --cpu-prof)

wall ~3.9-5.6s。上位はすべて「アロケーション由来」:

| self | share | frame |
|---|---|---|
| ~1.0-1.8s | 27-32% | (garbage collector) — V8 側。memory.grow コピー + host-call の JS churn |
| ~440-545ms | 10-12% | __rt_arr_push |
| ~260-320ms | 6-7% | __rt_eq |
| ~200-360ms | 5-6% | __rt_heap_grow_check |
| ~180ms | 5% | __rt_arr_get |
| ~150ms | 4% | __rt_str_eq |
| ~100ms | 3% | collect_free_vars_expr (codegen/common/analysis) |

user 関数は collect_free_vars_expr / lookup_ctor / compact_string_fingerprint /
env_lookup が上位。#799 の O(N²) 名前走査系は解消済みで、残る支配項は
**allocation churn そのもの** (V8 GC + __rt_arr_push + heap_grow_check で
~45%)。次の一手は「配列の再確保を減らす」方向 (capacity 事前確保、
ArrayBuilder 化、リテラル再構築のメモ化) が示唆される。

## メモリ (VIBE_WASM_MEMORY_STATS=1)

重量級 full-closure compile 1 回で:

```
[wasm-memory] run pages=5538 bytes=362938368 heap_ptr=362906740 rss=441372672
```

- **bump-heap 高水位 ~362MB / RSS ~441MB**。bump は解放しないので
  compile 1 回 ≒ 363MB のアロケーション総量。
- `__rt_heap_grow_check` が CPU 5-6% を占めるのはこの成長分の
  memory.grow (+V8 側のバッファコピーが GC 時間に計上) と対応する。

## CI プロファイル (ci.yml "selfhost-only-gate (moon-free)")

| step | warm cache (例: run 29190263031) | cold cache (例: run 29162041822) |
|---|---|---|
| Selfhost-only gate | 2m0s | 3m0s |
| unit-test runner (allowlist) | 3m15s | **31m14s** |
| suite coverage gate (#535) | 3m6s | **31m4s** |
| 合計 | ~8.5m | **~65m** |

compiler source を触った commit は persistent cache のフィンガープリントが
変わり、全 allowlist テスト (~340 file) がフルクロージャ再コンパイルに
なって 10 倍化する。1 compile ~5s × 2 gate ×~340 file がそのまま CI の
支配項 = **compile 速度/メモリの改善がそのまま cold CI を短縮する**。

## このプロファイルに基づく第1弾の修正 (同ブランチ)

profile の caller 集計 (cpuprofile の parent 帰属) で特定した 2 箇所:

1. **perceus `copy_ints`** — `__rt_arr_push` 439ms 中 253ms の単独最大
   呼び出し元。branch/match arm ごとの snapshot を push ループで作っていた。
   `Array::slice(src, 0, len)` (1 allocation + memory.copy) に置換。
2. **import_alias_rewrite** — (a) `alias_map_without_{name,names,pat,params}`
   が「削除対象が無くても毎 binder でコピー」→ 事前スキャンして無変更なら
   入力 map を共有して返す。(b) `rewrite_import_alias_expr` が alias 0 件でも
   AST 全木を再構築 → 空 map なら identity を返す fast path。

結果 (同一 corpus、byte-parity で意味論保存を確認済み):

| 指標 | before | after | delta |
|---|---|---|---|
| wall | 3867ms | 3332ms | −14% |
| CPU total | 3.63s | 3.09s | −15% |
| bump-heap 高水位 | 362.9MB | 255.8MB | **−30%** |
| RSS | 441MB | 389MB | −12% |
| `__rt_arr_push` self | 439ms | 130ms | −70% |
| V8 GC | 985ms | 695ms | −29% |

残る上位: `__rt_eq` (collect_free_vars の線形名前走査、#799 の Map index
パターン適用候補)、perceus snapshot 自体の 113ms (`__rt_arr_slice`) は
dirty-tracking 化しないと消えない。

## 今回入れた profiler 改善

- `Profiler::heap_bytes` builtin (linear lane, `vibe.profile-heap-bytes`):
  ゲスト内から bump-heap pointer を読める。now_us の allocation 版。
- `scripts/profile_selfhost_compile.sh`: cpu-prof + self-time 集計 +
  メモリ統計のワンコマンド化。
- 既存の runner 計測 (`VIBE_WASM_MEMORY_STATS` / `VIBE_PROFILE_MEMORY_MARKS`)
  と合わせて skill / cheatsheet に記載を整備。
- follow-up (bootstrap bump 後): compile-lite `--profile-tsv` に per-stage
  heap 列を追加できる (CLI source が heap_bytes を使えるようになってから)。
