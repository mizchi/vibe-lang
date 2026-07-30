# vibe profiling — memory & benchmarking design

vibe の計測基盤の設計と現状。メモリプロファイラはアロケーションモデルに直結している。

## メモリモデル（前提）

- **linear backend（既定 / `vibe build --release` / `viberun`）**: **bump allocator**。
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
| **4** | 関数別 alloc 属性（massif/heaptrack 相当）| break ビルド再利用（`dbg_break`）| ✅ **実装済み**: `--alloc-site` |

## Tier 1: `vibe run --mem`（実装済み）

`__heap_ptr` を `_start` 実行の前後で読み、差分を「allocated」として出力する。無計装・ほぼゼロ
オーバーヘッド。プログラム出力（stdout）は汚さず、レポートは stderr に出す。

```
$ vibe run --mem prog.vibex
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
$ vibe run --mem grow.vibex         # >4 MiB を確保するプログラム
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
$ vibe run --mem-sample long.vibex
vibe::memsample t_us=1235 heap=2459624
vibe::memsample t_us=2314 heap=4571336
…
vibe: heap samples — 12 over 1.21 ms … 13.36 ms, 2.4 MiB -> 19.2 MiB (peak 19.2 MiB)
```

各 `vibe::memsample` 行は機械可読（`t_us`=経過、`heap`=`__heap_ptr` bytes）。サンプル数は
実行時間と間隔に依存（プログラムが 1 間隔より速いと 0 サンプル）。

## Tier 4: 関数別 alloc 属性（実装済み）

`vibe run --alloc-site[=N]`。**massif/heaptrack 相当の by-frame アロケーションプロファイル**を、
**新しい計装なしで** break ビルドを再利用して得る。break codegen は全ユーザー関数の入口に
`vibe::dbg_break`、各文境界に `vibe::dbg_line` を出すので（DAP の breakpoint/step 用）、runner は
その両 hook を**サンプル点**として使い、各点で `__heap_ptr` を読んで **前回サンプルからの bump 差分を
「その時点で実行中だった最内関数（backtrace の frame[0]）」へ加算**する。文境界でも毎回 backtrace を
読み直すので、ヘルパーが return した後にその呼び出し元が次の文で確保した分は**呼び出し元**に付く
（入口のみのサンプルだと return した callee に誤って付く問題を緩和）。`dbg_break` は let/mut に
関係なく必ず発火するので関数単位のカバレッジは完全（pure な mut ループの関数も捕捉する）。
break ビルド再利用なので、デフォルトの自己コンパイル経路は byte-identical（fixpoint 維持）。

```
$ vibe run --alloc-site sites.vibex       # heavy()/light() を呼ぶプログラム
1250
vibe::allocsite fn=heavy line=1 bytes=181200
vibe::allocsite fn=light line=7 bytes=1456
vibe: alloc sites — 2 function(s), 178.4 KiB attributed total, top 2 shown
```

各 `vibe::allocsite` 行は機械可読（`fn`=関数名、`line`=宣言行 [funcmap 解決、無いと `?`]、
`bytes`=加算されたヒープ増分）。stderr に出し、stdout はプログラム出力のまま。`=N` または
`VIBE_ALLOC_SITE_TOP` で報告する上位件数を制限（既定 20）。`VIBE_ALLOC_SITE=1` で runner が
有効化、launcher が `--break` と同じ計装でコンパイルしつつ `VIBE_BREAK` は設定しない（pause なし）。

**粒度と限界**: 属性は**関数単位**（行単位ではない）のリーフ属性で、サンプル点（関数入口＋文境界）
**間**の差分を1関数に丸めるため近似である。`__heap_ptr` 差分ベースなので arena（解放なし）の*確保*量で
あり live-set ではない（メモリモデル参照）。毎サンプルで backtrace を取るので `--alloc-site` 実行は
通常より遅い（プロファイル実行のみのコスト）。

**残る誤属性**: 呼び出し元が helper を呼んだ後、**文境界の無い区間**（`mut` 代入のみの while ループ等。
`mut` let / 代入は `dbg_line` を出さない）で確保すると、その間サンプルが取れず、tail 加算が直近の
sample 点の関数（= 戻ってきた callee）にまとめて付く。例:
`let x = helper(); let mut t=""; while … { t = concat(t, …) }` では大きな確保が helper に誤計上される。
正確な per-allocation 属性には**確保サイト計装（codegen で各確保点に hook）か return hook** が要る
— これは設計当初から tier 4 の opt-in 計装ビルド（`vibe::alloc_site`）として想定した重い変更で、
本実装（runner のみ・codegen 非変更）の範囲外。現状はリーフが文境界で確保する一般形
（builder が concat して返す等）で正しく、上記パターンで粗くなる近似プロファイラとして使う。
test: `scripts/test_vibe_alloc_site.sh`。

## `vibe bench`（実装済み）

`bench "name" { }` 構文と `vibe::profile-now-us` はあったが計測ハーネスが無かった。`vibe bench`
を追加した。実装は runner 側（`viberun --bench`）で、**codegen 変更なし**:

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

**粒度: bench ブロック個別（実装済み）**: codegen が各 `bench "name" { }` を `__bench_<name>` 関数として
export する（`__no_entry__` ビルド時のみ。通常ビルド・コンパイラ自己コンパイルは byte-identical）。
runner（`--bench`）は export を列挙して **ブロックごとに warm 計測**し、`label=<file>::<name>` で
1 行ずつ報告する。`__bench_*` が無い wasm（旧コンパイラ生成 / `test {}` のみのファイル）は
`_start` 全体（ファイル単位）にフォールバックする。

```
$ vibe bench multi_bench.vibe
vibe::bench label=multi_bench.vibe::light iters=1000 ns_min=… … bytes_per_op=0
bench multi_bench.vibe::light: 1000 iters — … ns/op …
vibe::bench label=multi_bench.vibe::heavy iters=1000 ns_min=… … bytes_per_op=0
bench multi_bench.vibe::heavy: 1000 iters — … ns/op …
```

実装: codegen は `lib/@vibe/compiler/codegen/wasi/linked_compile.vibe`（export セクションで `test_fn_names` の
`__bench_*` を `all_export_names` に追加）、計時は runner（`bench()` が module export を走査して
ブロック単位 / フォールバックを選ぶ）。test: `scripts/test_vibe_bench.sh`（per-block 3 assertions）。

さらに精度を上げるなら:

- µs 級でなく ns 級を狙うなら内側 batch（K 回回して割る）で per-call overhead を相殺
- 2 backend（linear / gc）の別レポート
- 回帰検出: `(label, backend, source-hash)` で baseline 比較、% 退行を flag → CI ゲート

## 注意点

- `profile-now-us` は host 越しの wall-clock。micro は必ず batch。
- bump allocator は断片化/解放の概念がなく peak=total（これが linear の意味論）。
- 計測は本質的にブレる → 反復＋ロバスト統計で吸収。
