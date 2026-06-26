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
| **2** | `memory.grow` イベント（成長タイムライン）| ホストのみ | ✅ **実装済み**: `--mem` の一部 |
| **3** | アロケーション時系列サンプリング | ホストのみ（epoch）| ✅ **実装済み**: `--mem-sample` |
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

## Tier 2: 成長タイムライン（実装済み）

`--mem` 実行時、runner は wasmtime の `ResourceLimiter`（`MemLimiter`）で `memory.grow` を
すべて記録する。guest の `memory.grow` も host の `Memory::grow`（bump 文字列確保）も
wasmtime はこの limiter を通すので、タイムラインは完全。計装ゼロ・ホスト側のみ。

```
$ vibe run --mem grow.vibe          # >4 MiB を確保するプログラム
vibe::mem heap_base=131144 heap_peak=6270152 allocated=6139008 committed=6291456 grow_events=32
vibe: memory — allocated 5.9 MiB …, committed 6.0 MiB, 32 growth event(s)
vibe::memgrow t_us=2066 from=4194304 to=4259840 pages=+1
vibe::memgrow t_us=2107 from=4259840 to=4325376 pages=+1
…
vibe:   growth 4.0 MiB -> 6.0 MiB across 32 event(s), 2.07 ms … 2.50 ms
```

各 `vibe::memgrow` 行は機械可読（`t_us` = run 開始からの経過、`from`/`to` = bytes、`pages` = 追加ページ）。

**限界**: 生成 wasm の初期メモリは **64 ページ（4 MiB, `default_wasi_memory_min_pages`）** なので、
4 MiB 未満で収まるプログラムは grow が発生せず `grow_events=0`。つまりこれは**ページコミットの
粗いタイムライン**（4 MiB 超のときに有効）。細粒度のアロケーション曲線が要るなら tier 3
（`__heap_ptr` を `dbg_line`/epoch でサンプリング）。
上の例は bump allocator が **1 ページ（64 KiB）ずつ** grow していることも示している
（syscall を減らすなら成長チャンクを大きくする余地）。

## Tier 3: 時系列サンプリング（実装済み）

`vibe run --mem-sample[=MS]`（既定 1ms 間隔）。runner は wasmtime の **epoch interruption** を
使い、バックグラウンドスレッドが MS ごとに engine epoch を increment、ゲストのチェックポイント
（関数入口・ループ back-edge）で epoch-deadline コールバックが発火して `__heap_ptr` を読む。
これで **初期メモリ（4 MiB）内**でも heap の推移が見える（tier 2 の grow イベントが拾えない領域）。
ホスト側のみ・計装なし。epoch checks のコストは `--mem-sample` 時のみ（通常 / `vibe bench` は無影響）。

```
$ vibe run --mem-sample long.vibe
vibe::memsample t_us=1235 heap=2459624
vibe::memsample t_us=2314 heap=4571336
…
vibe: heap samples — 12 over 1.21 ms … 13.36 ms, 2.4 MiB -> 19.2 MiB (peak 19.2 MiB)
```

各 `vibe::memsample` 行は機械可読（`t_us`=経過、`heap`=`__heap_ptr` bytes）。サンプル数は
実行時間と間隔に依存（プログラムが 1 間隔より速いと 0 サンプル）。

## `vibe bench`（実装済み）

`bench "name" { }` 構文と `vibe::profile-now-us` はあったが計測ハーネスが無かった。`vibe bench`
を追加した。実装は runner 側（`moonrun_wt --bench`）で、**codegen 変更なし**:

- 再実行可能な test entry（`__no_entry__` が `bench{}`/`test{}` body を走らせる `_start`）を、
  **同一の warm インスタンス上で N 回呼ぶ**。warmup → 計測。
- 各呼び出しを `Instant` で計時し、`__heap_ptr` をバッチ前後で読んで **bytes/op**（tier 1 を再利用）。
- 統計: **min / p50 / p95 / mean / ops·sec** ＋ **bytes/op**。

```
$ vibe bench examples/simple_bench.vibe
vibe::bench label=simple_bench.vibe iters=1000 ns_min=47 ns_p50=49 ns_p95=51 ns_mean=49 ops_per_sec=20408163 bytes_per_op=0
bench simple_bench.vibe: 1000 iters — 49 ns/op (min 47 ns, p50 49 ns, p95 51 ns), 20.4M ops/s, 0 B/op
```

`vibe bench <file> [--iters N] [--warmup N]`。`vibe::bench …` は機械可読（CI/比較が parse）。
env: `VIBE_BENCH_ITERS` / `VIBE_BENCH_WARMUP` / `VIBE_BENCH_LABEL`。test: `scripts/test_vibe_bench.sh`。

**現状の粒度と限界**: `__bench_*` は未 export なので **ファイル単位**（その file の bench/test body の和）
で測る。`*_bench.vibe` に bench を 1 つ置く運用なら実質ピンポイント。次段で精度を上げるなら:

- `__bench_<name>` を export → runner が **bench ブロック個別**に計時（codegen 変更が要る）
- µs 級でなく ns 級を狙うなら内側 batch（K 回回して割る）で per-call overhead を相殺
- 2 backend（linear / gc）の別レポート
- 回帰検出: `(label, backend, source-hash)` で baseline 比較、% 退行を flag → CI ゲート

## 注意点

- `profile-now-us` は host 越しの wall-clock。micro は必ず batch。
- bump allocator は断片化/解放の概念がなく peak=total（これが linear の意味論）。
- 計測は本質的にブレる → 反復＋ロバスト統計で吸収。
