# 内部 Span トレーシング設計 (提案)

`vibe bench` / `--profile-tsv` / `node --cpu-prof` が今それぞれ別々に答えている
「どこに時間とメモリが行ったか」を、**1つのネストしたスパン木**に統合するための
設計。将来 OpenTelemetry へ写せる形を最初から意識する。

**Span は代数 effect として表現する。** §3 の実測がその選択を支持している —
perform は素の関数呼び出しより 1.7 倍高いだけで、アロケーションはゼロ、
何も perform しない関数が row に `Trace` を持つコストは測定限界以下だった。

これは提案であり、まだ実装されていない。§3 の数値は
[`bench/tracing/trace_effect_bench.vibe`](../bench/tracing/trace_effect_bench.vibe) と
[`bench/tracing/trace_effect_shapes_test.vibe`](../bench/tracing/trace_effect_shapes_test.vibe)
を現行 stage2 で実際にコンパイル・実行して得たもので、どちらもコミットされている。

## 1. 現状の計測手段と、それぞれが答えられないこと

| 手段 | 答えられること | 答えられないこと |
|---|---|---|
| `vibe bench` | `bench {}` ブロック単位の ns/op・bytes/op | ブロックの**内訳** |
| `--profile-tsv` / `VIBE_PROFILE_TSV` | ハードコードされた7ステージの経過時間 | その7つ以外・ネスト・モジュール単位・**メモリ** |
| `node --cpu-prof` | wasm 関数の self 時間 | アロケーション量。node runner 限定 (`vibe bench` は wasmtime) |
| `Profiler::now_us` / `heap_bytes` | 任意の1区間 | 手で配線する必要がある (§1.1) |
| `VIBE_WASM_MEMORY_STATS=1` | 実行終了時の1点 | 実行中の推移 |
| `vibe.trace` custom section | 関数 entry の実行順 (先頭4096) | 時間・メモリ・ネスト |

### 1.1 「手で配線する」の実際のコスト

`--profile-tsv` の7ステージは、タプルで戻り値に相乗りして3層を遡っている:

```vibe
// lib/@vibe/compiler/cli_support.vibe:129
export fn compile_release_file_mode_uncached_profiled(input_path: String, entry_name: String, mode: String)
  -> (Bytes, Int, Int, Int, Int, Int, Int) with Exception + Fs + Profiler
```

`Int` が6つ並んでいるのは load/type/bundle/parse/compile/total の µs である。
ステージを1つ足すと、このタプル型が `cli_support.vibe` と `dispatch.vibe` の
6箇所で変わる。**ステージ一覧が長期間7つのまま動いていないのはこれが理由**で、
同じ理由でメモリ次元が入っていない (heap も測るとタプルは13要素になる)。

さらにこの経路は `_profiled` 版の関数を本体と**二重に持って**いる
(`compile_release_file_mode` / `..._profiled`、
`selfhost_cli_low_level_args` / `..._profiled`)。計測を足すたびに分岐が増える。

### 1.2 実測で見えた、今の計測では詰められない例

[docs/perf-snapshot-2026-08-07.md](perf-snapshot-2026-08-07.md) より:

- **`array_empty` が CPU の 4.3%**。配列のデフォルト容量を 8→2 にして heap が
  13.9% 下がったが、「配列の最終長の分布」は今のツールで取れないので、
  なぜ下がったかは3点の A/B からの逆算にとどまっている。
- `bench/perf/heap_baseline.txt` は **173行あって、うち172行は「どのフェーズが
  太ったか」を人間が後から調べて書いた散文**である。フェーズ単位の heap delta が
  同じスナップショットに入っていれば、この散文の大半はデータで置き換えられる。

## 2. ゲスト側の表面 — 代数 effect

operation は CamelCase (代数レコードの constructor であって関数ではない —
CLAUDE.md / #1458 / ADR-0084):

```vibe
effect Trace {
  SpanBegin(String) -> Int      // -> span id
  SpanEnd(Int) -> Unit
  SpanAttr(Int, String, String) -> Unit
  Event(String) -> Unit
}
```

```vibe
fn typecheck_module(path: String) -> TypeEnv with Fs + Trace {
  let sp = perform Trace::SpanBegin("typecheck")
  perform Trace::SpanAttr(sp, "module", path)
  let env = ...
  perform Trace::SpanEnd(sp)
  env
}
```

§1.1 のタプル配線と決定的に違うのは、**戻り値の型が変わらない**こと。
`compile_release_file_mode_profiled` とその7要素タプル、そして `_profiled`
二重関数は消え、`compile_release_file_mode` の row に `Trace` が付くだけになる。

### 2.1 handler がそのまま sink になる — これが代数化の本体

capability builtin だと sink はランタイムに焼き付き、切り替えは環境変数になる。
代数 effect なら **sink はプログラムの選択**になる:

| handler | 得られるもの |
|---|---|
| `SpanBegin(n) => resume(0); SpanEnd(i) => resume(())` | 計測オフ (それでも 4.7ns/perform、§3) |
| span を配列に積む | メモリ内 span 木 (**実測で動作確認済み**、§3.4) |
| NDJSON を `Fs::write_file` | ファイルエクスポート |
| テストが span 列を assert | **トレース自体のユニットテスト** |
| ring buffer に固定長レコードを書く | 低オーバーヘッドのバッチ出力 (§5) |

最後の行が重要で、**ring buffer は「1つの handler の実装詳細」に降格する** —
インタフェースではない。当初この設計は「span ごとの host call が 50-100ns
かかるから ring buffer が必須」という前提で書いていたが、§3 の実測で
perform は host call より1桁安いことが分かったので、その前提は崩れた。

### 2.2 スコープ構文 `span "name" { body }`

**これは純粋な脱糖で書ける。言語機能の追加は要らない。**

当初この節は「`span` の代数的な解は scoped operation (計算を引数に取る
operation) だが、higher-order effectful block は #1347-2 で非対応と
明文化されているので今すぐ書けない」と書いていた。**それは要求を取り違えていた。**
必要なのは「両方の出口で SpanEnd が走る」ことだけで、それは try/finally であり、
今の vibe で書ける:

```vibe
span "risky" { body }

// ↓ 脱糖後 (これがそのまま今コンパイルできる形)

let sp = perform Trace::SpanBegin("risky")
let r = handle { body } with Exception {
  Throw(e) => {
    perform Trace::SpanEnd(sp)
    throw(e)
  }
}
perform Trace::SpanEnd(sp)
r
```

`throw(x)` が parse 時に `perform Exception::Throw(x)` へ脱糖されるのと同じ層
(#640) で処理できる — **parser/desugar の仕事であって、effect system の
仕事ではない。**

実測 (`bench/tracing/trace_effect_shapes_test.vibe` の
"spans close on the throw path too")。ネストした2つの span を、正常終了と
throw の両方で通したときの trace log:

```
normal: r=6   log=0>outer,1>inner,<1,<0   depth_after=0
throw:  r=-1  log=0>outer,1>inner,<1,<0   depth_after=0
```

**log がバイト単位で一致する。** span は LIFO で閉じ、深さは 0 に戻る。
scoped span に求められる性質はこれで全部満たされている。

scoped operation の方が概念的には綺麗だが、それは
「evidence を arm 境界を越えて migrate する」ための機構 (資料 p133 の
evidence vector、ADR-0076 に残っている spine) を必要とする。
**その機構は span のためには要らない。**

> 残る差: OTel の span には `status` があり、異常終了を記録できる。上の脱糖なら
> Exception arm の側で `perform Trace::SpanAttr(sp, "status", "error")` を
> 足すだけでよく、これも脱糖で閉じる。

## 3. 実測 — 代数 effect にしてよいのか

`bench/tracing/trace_effect_bench.vibe` を現行 stage2 に対して `--iters 200`。
各ベンチは10,000反復 × 2 perform = 20,000 perform。

```bash
VIBE_RUNNER=$PWD/runtime/viberun/target/release/viberun \
  VIBE_CLI_WASM=<stage2.wasm> ./runtime/vibe bench \
  bench/tracing/trace_effect_bench.vibe --iters 200
```

### 3.1 perform 1回のコスト

| 形 | 10k反復の ns_p50 | 1操作あたり |
|---|---|---|
| 計装なしのループ (floor) | 5,943 | 0.59 ns/iter |
| 素の関数呼び出し ×2 | 70,799 | **3.2 ns/call** |
| `perform` ×2 (ループ内・名前付き fn 越し) | 108,956 | **5.4 ns/perform** |

**perform は素の関数呼び出しの 1.7 倍。** `bytes_per_op` は perform 側で 32、
呼び出し側で 0 — この 32 バイトは 20,000 perform に対する値なので
**perform 自体のアロケーションはゼロ**で、handle 1回あたりの固定費である。

参考: 上で前提にしていた host import 呼び出しはおよそ 50-100ns。
**perform はそれより1桁安い。**

### 3.2 row に `Trace` を持つだけのコスト — 測定限界以下

5段の pass-through 関数チェーン (どれも perform しない) を 10,000 回:

| | ns_p50 | bytes/op |
|---|---|---|
| 全段の row に `Trace` あり | 90,175 | 0 |
| row なし | 90,827 | 0 |

**差は誤差の中** (traced の方がわずかに速いくらい)。50,000 回の呼び出しを
通しても、`Trace` を row に持つだけでは何も払っていない。

これが決定的で、**コンパイラの奥に span を1つ置くと CLI までの署名が変わる**
という §1 の懸念は「署名は変わるが実行時コストは伴わない」に縮む。

### 3.3 handler が時計を読むかどうかが支配項

同じ 20,000 perform を、arm の中身だけ変えて:

| handler | ns_p50 | 1 perform あたり |
|---|---|---|
| 数えるだけ | 94,259 | **4.7 ns** |
| `Profiler::now_us()` を境界ごとに1回 | 856,240 | **42.8 ns** |

**時計が 38ns、effect 機構が 4.7ns。9倍の差。** span のコストは
「effect にしたこと」ではなく「時刻を読むこと」で決まる。

代数形だとこれが**プログラム側の選択になる**: 呼び出し回数だけ欲しい handler は
時計を読まず 9 倍安く済む。capability builtin にすると、この判断が builtin の
中に焼き付いてしまう。

### 3.4 動くと確認した形

`bench/tracing/trace_effect_shapes_test.vibe` (6 test、全 pass):

| test | 形 | 結果 |
|---|---|---|
| perform behind a named fn | 名前付き fn の中で perform、handler は1つ上 | ok |
| perform inside a while loop | **`while` ループの中で perform** | ok (§8.3) |
| perform four call levels down | 4段の名前付き fn を越えて perform | ok |
| handled body calls a local closure | handled body が**ローカルクロージャ**を呼ぶ | ok (§8.2) |
| perform inside an annotated closure literal | **row 注釈付きクロージャリテラルの中で** perform (#761) | ok |
| stateful handler builds a span tree | handler が配列と深さを持ち **span 木を組み立てる** | ok |

最後の test が assert しているのがそのまま span 木である — `mid` が depth 0 で開き、
2つの leaf が depth 1 に入り、handle を抜けた時点で depth が 0 に戻る。

> 注意: このファイルは**ユニットテストバッテリには入っていない**。
> `scripts/unit_test_runner.sh` は `examples/` / `lib/` / `fixtures/` 配下の
> `*_test.vibe` しか拾わない。設計が採用されたら `lib/` へ移してバッテリで
> ロックする。

## 4. 分散トレーシングへの写像

| vibe | OTel |
|---|---|
| `SpanBegin` の name | `name` |
| handler が読む `Profiler::now_us` | `startTimeUnixNano` / `endTimeUnixNano` |
| handler が採番する span id | `spanId` (64bit) |
| handler が持つ深さスタックの親 | `parentSpanId` |
| `VIBE_TRACEPARENT` (W3C traceparent) | `traceId` (128bit) |
| handler が読む `Profiler::heap_bytes` の差分 | attribute `vibe.heap_bytes` |

**span id・親子・trace context をすべて handler が持つ**ので、コンパイラ側の
コードは `perform Trace::SpanBegin(name)` だけを書き、context 伝播の方針
(サンプリング、id 生成、traceparent の解釈) は handler の差し替えで変わる。

`heap_bytes` を span 境界で読めるのが既存手段に対する追加価値である。時間だけなら
`--cpu-prof` でも取れるが、**アロケーションを区間に帰属させる手段が今どこにもない**。
ただし §3.3 のとおり、これも host call なので時計と同じ ~38ns を払う。

### 4.1 なぜこれがこのリポジトリで効くか

ビルドは**既に多プロセスの木**であり、現在の道具はそれを1つのものとして見られない:

- `scripts/generations.sh build` = seed → stage1 → stage2 → stage3、別プロセスで4回のフルコンパイル
- `scripts/unit_test_runner.sh` は数百のコンパイル+実行プロセスに fan-out
- doctest の fan-out (#819)、`parallel_warm_pool.sh`

今 CI バッテリの内訳を知るには shard ごとの `wall_ms` を bash で足し合わせる
しかなく、`docs/ci-speed.md` は実際にその手作業で書かれている。
子プロセスに `VIBE_TRACEPARENT=00-<trace_id>-<parent_span_id>-01` を渡せば
1回の run が1本のトレースになり、クリティカルパスがそのまま出る。

## 5. 出力形式

`VIBE_TRACE_OUT` が指すファイルへ NDJSON を1行1レコードで:

```json
{"tid":"<32hex>","sid":"<16hex>","pid":"<16hex>","name":"typecheck",
 "t0":123456,"t1":789012,"heap0":1024,"heap1":8192,"attrs":{"module":"..."}}
```

OTLP-protobuf を採らないのは意図的: 依存が要らず、grep でき、`jq` で集計できる。
Jaeger/Tempo に向けたくなった時点で ~100行の変換器を足せばよい。

高頻度で回すときは、NDJSON を直接書く代わりに linear memory 上の固定32バイト
ring buffer に積んでホストが吸う handler に差し替える (既存の `vibe.trace`
custom section が `linked_compile.vibe:3441` で同じ構造の領域を予約している)。
§2.1 のとおりこれは**1つの handler の実装**であって、インタフェースではない。

## 6. 実装順

| 段 | 内容 | コンパイラ変更 |
|---|---|---|
| 0 | `VIBE_TRACEPARENT` 伝播 + ホスト側だけで1プロセス1 span の NDJSON 出力 (`run_wasm_vibe_host_runner.sh` / `unit_test_runner.sh` / `generations.sh`) | **不要** |
| 1 | `effect Trace` を contract に置き、`--profile-tsv` の7タプル配線を perform へ置き換える。TSV は span 木から生成して `test_cli_core.sh` 互換を保つ | **不要 (言語機能は既にある — §3)** |
| 2 | `vibe bench` が bench ブロックごとに span 内訳を出す | 要 (runner) |
| 3 | `span {}` スコープ構文 (§2.2 の脱糖。`throw` → `perform Exception::Throw` と同じ層) | 要 (parser/desugar のみ) |
| 4 | OTLP エクスポータ | 不要 |

**段1にコンパイラ変更が要らない**のが今回の実測でいちばん大きい収穫で、
`effect Trace` の宣言と handler は今日書ける vibe のコードだけで済む。

## 7. この設計が引き受けていないこと

- **サンプリングプロファイラの代わりにはならない。** span は人が置いた境界しか
  見ない。`array_empty` が 4.3% であることは `--cpu-prof` が見つけたもので、
  span 木では (誰かがそこに span を置かない限り) 見えない。両方要る。
- **`bytes_per_op` は置き換えない。** bench の bytes/op は bump 高水位の差分で
  決定的な数値であり、ゲートに使える。span の heap delta はその内訳である。
- **span の粒度は人が決める。** 段1 でどこに span を置くかはこの文書では
  決めていない (フェーズ境界から始めるのが自然)。
- **wasm-gc backend は対象外。** 代数 effect handler は linear backend のみ
  (`gc/backend_expr.vibe` は `with Exception` のスタブだけ)。
  `VIBE_TEST_BACKEND=gc` の test/bench では `Trace` は使えない。

## 8. 副産物: ドキュメントとの食い違い

probe を書く過程で cheatsheet と実測が合わない点が3つ出た。いずれも未修正。

1. **handle arm の区切りは `,` ではなく `;`。** cheatsheet の代数 effect の例
   (`docs/cheatsheet.md:912`) は arm が1つしかないので、複数 arm の綴りが
   どこにも書かれていない。`,` で書くと
   `expected ';' or '}' in handle arm list` になる。
2. **「handled body がローカルクロージャを呼ぶと NG」は現行では再現しない。**
   cheatsheet の適格性表 (`docs/cheatsheet.md:1264` 付近) は
   `handle { bump(ask_once()) }` で `bump` がローカルクロージャなら **NG** と
   書いているが、`bench/tracing/trace_effect_shapes_test.vibe` の
   "handled body calls a local closure" はまさにその形で**コンパイルも実行も通った**。
   その後の修正で通るようになったのか、元の再現に自分が写しそこねた差異が
   あるのかは切り分けていない — 表を直す前に再測定が要る。
3. **「loop 内の perform は compile error」は tail-resumptive には当てはまらない。**
   この記述は first-class resume (suspend CPS) の制約リストの中にあるが、
   読むと一般則に見える。上のテストの "perform inside a while loop" は
   tail-resumptive な handler で
   ループ内 perform が通る。制約の適用範囲が2つに分かれていることが
   本文から読み取れない。
