# vibe profiling — memory & benchmarking design

vibe の計測基盤の設計と現状。メモリプロファイラはアロケーションモデルに直結している。

## メモリモデル（前提）

- **linear backend（既定 / `vibe build --release` / `moonrun_wt`）**: **bump allocator**。
  `__heap_ptr`（export 済みの i32 mut global）が単調増加のヒープ先端。**free がない（arena）**。
  → 1 回の実行内では **peak == total allocated**。プロファイル＝*アロケーション*プロファイル
  （総量・レート・サイト別）であって live-set ではない。
- **wasm-gc backend（opt-in）**: host GC を使うので live-set を測れるが、codegen ギャップあり
  （HOF / Iterator 等、CLAUDE.md 参照）。

ホスト側（`vibe_alloc_packed_str`）も同じ `__heap_ptr` に bump するので、`__heap_ptr` は
guest＋host を合わせた総ヒープ使用量を表す。

## 実装ティア（コスト順）

| tier | 内容 | 計装 | 状態 |
|---|---|---|---|
| **1** | 総ヒープ / ピーク（`__heap_ptr` 差分）| ゼロ | ✅ **実装済み**: `vibe run --mem` |
| 2 | `memory.grow` イベント（成長タイムライン）| ホストのみ | 設計済み（wasmtime `ResourceLimiter`）|
| 3 | アロケーション時系列サンプリング | `dbg_line` / epoch 流用 | 設計済み |
| 4 | サイト別 alloc 属性（massif/heaptrack 相当）| opt-in ビルド（`vibe::alloc_site`）| 設計済み |

## Tier 1: `vibe run --mem`（実装済み）

`__heap_ptr` を `_start` 実行の前後で読み、差分を「allocated」として出力する。無計装・ほぼゼロ
オーバーヘッド。プログラム出力（stdout）は汚さず、レポートは stderr に出す。

```
$ vibe run --mem prog.vibe
<program stdout>
vibe::mem heap_base=131144 heap_peak=258152 allocated=127008 committed=4194304
vibe: memory — allocated 124.0 KiB (127008 B), peak heap 252.1 KiB, committed 4.0 MiB
```

- `vibe::mem …` — 機械可読（ベンチ harness / CI が parse する用）
- `vibe: memory — …` — 人間可読

`allocated = heap_peak − heap_base`。linear では free がないので、これは実行全体で確保した総量。
pure / 純計算プログラムは `allocated=0`。`committed` は wasm memory のページ総量。

実装: runner は `VIBE_MEM=1`（`--mem` が設定）のとき `__heap_ptr`（`read_heap_ptr`）と
`memory` サイズを読んで `report_memory` で出力（trap しても出る）。test: `scripts/test_vibe_mem.sh`。

## ベンチマーカー設計（次段）

`bench "name" { }` 構文と `vibe::profile-now-us`（µs clock）は既にある。harness を足す:

- warmup → 反復自動スケール（合計 T µs まで / 安定まで）、µs 解像度対策に内側 batch（K 回回して割る）
- 統計: min / median / mean / stddev / p95 / ops·sec、外れ値トリム
- **メモリ併記**: 各 bench で `__heap_ptr` 差分（bytes/op）を時間と並べる（tier 1 を再利用）
- 2 backend（linear / gc）を別レポート
- 回帰検出: `(name, backend, source-hash)` で baseline 比較、% 退行を flag → CI ゲート

## 注意点

- `profile-now-us` は host 越しの wall-clock。micro は必ず batch。
- bump allocator は断片化/解放の概念がなく peak=total（これが linear の意味論）。
- 計測は本質的にブレる → 反復＋ロバスト統計で吸収。
