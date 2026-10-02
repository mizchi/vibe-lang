# Internal span tracing

A design for unifying "where did the time and memory go", which `vibe bench`,
`--profile-tsv` and `node --cpu-prof` each answer separately today, into **one
nested span tree**, shaped from the start so it can be mapped onto
OpenTelemetry.

**Status.** Stage 0 — host-side, one span per process, propagated through
`VIBE_TRACEPARENT` — is implemented (`scripts/trace_lib.sh`,
`scripts/trace_span.sh`, `scripts/trace_report.mjs`, regression-locked by
`scripts/test_trace_spans.sh`) and wired into `scripts/generations.sh`,
`scripts/generate_bundle.sh` and `scripts/unit_test_runner.sh` (§5.6–§5.11).
The guest-side surface — the `effect Trace` of §2 inside the compiler — is
**not implemented**: an attempt was rejected by the handle-eligibility check
and reverted (§5.5). §6 has the stages and their state.

**Spans are an algebraic effect.** The measurements in §3 support that choice:
a perform costs 1.7× a plain function call with zero allocation, and carrying
`Trace` on the row of a function that never performs costs nothing measurable.
§3's numbers come from compiling and running
[`bench/tracing/trace_effect_bench.vibe`](../../../bench/tracing/trace_effect_bench.vibe) and
[`bench/tracing/trace_effect_shapes_test.vibe`](../../../bench/tracing/trace_effect_shapes_test.vibe)
(both committed) on the stage2 of the time.

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

[docs/internal/reports/perf-snapshot-2026-08-07.md](../reports/perf-snapshot-2026-08-07.md) より:

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

### 2.2 Scope syntax `span "name" { body }`

**This is a pure desugaring. It needs no new language feature.**

What `span` needs is for `SpanEnd` to run on both exits of the body — the
normal one and the throwing one. That is try/finally, and current vibe can
write it:

```vibe
span "risky" { body }

// desugars to (this form compiles today)

let sp = perform Trace::SpanBegin("risky")
let r = handle { body } with {
  Exception::Throw(e) => {
    perform Trace::SpanEnd(sp)
    throw(e)
  }
}
perform Trace::SpanEnd(sp)
r
```

It belongs in the same layer that desugars `throw(x)` to
`perform Exception::Throw(x)` at parse time (#640): **this is parser/desugar
work, not effect-system work.**

Measured (`bench/tracing/trace_effect_shapes_test.vibe`, "spans close on the
throw path too"): the trace log for two nested spans, run once to normal
completion and once through a throw:

```
normal: r=6   log=0>outer,1>inner,<1,<0   depth_after=0
throw:  r=-1  log=0>outer,1>inner,<1,<0   depth_after=0
```

**The two logs are byte-identical.** Spans close in LIFO order and the depth
returns to 0, which is every property a scoped span needs.

A scoped operation (an operation that takes a computation as its argument)
would be the conceptually cleaner answer, but it needs the machinery for
migrating evidence across an arm boundary (the evidence vector on p133 of the
reference material; its spine survives in ADR-0076). **`span` does not need
that machinery.**

> What remains: an OTel span has a `status` that records abnormal termination.
> With the desugaring above, the Exception arm adds
> `perform Trace::SpanAttr(sp, "status", "error")`, so this closes within the
> desugaring too.

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
| perform inside a while loop | **`while` ループの中で perform** | ok |
| perform four call levels down | 4段の名前付き fn を越えて perform | ok |
| handled body calls a local closure | handled body が**ローカルクロージャ**を呼ぶ | ok |
| perform inside an annotated closure literal | **row 注釈付きクロージャリテラルの中で** perform (#761) | ok |
| stateful handler builds a span tree | handler が配列と深さを持ち **span 木を組み立てる** | ok |

最後の test が assert しているのがそのまま span 木である — `mid` が depth 0 で開き、
2つの leaf が depth 1 に入り、handle を抜けた時点で depth が 0 に戻る。

> 注意: このファイルは**ユニットテストバッテリには入っていない**。
> `scripts/unit_test_runner.sh` は `examples/` / `lib/` / `fixtures/` 配下の
> `*_test.vibe` しか拾わない。設計が採用されたら `lib/` へ移してバッテリで
> ロックする。

### 3.5 Backend: wasm-gc as well as linear

Every test in `bench/tracing/trace_effect_shapes_test.vibe` also passes under
`VIBE_TEST_BACKEND=gc`, and a separate probe confirmed the suspend shape that
stores a first-class `resume` as a value.

Effects are lowered **before** codegen, by passes both backends share: the gc
backend runs `evidence_dict_pass` (`codegen/gc/backend_body_wasi_module_gc_impl.vibe`)
and fails the compile with its `edp_errs`. The `EHandle` arm of
`codegen/gc/backend_expr.vibe` (`try_table`) only receives the handles those
passes leave in place; a tail-resumptive or suspend-CPS handler is gone before
codegen. **So `Trace` works on the gc backend too.** Two older texts still say
otherwise; §8 lists them.

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
しかなく、`docs/internal/operations/ci-speed.md` は実際にその手作業で書かれている。
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

## 5.5 実装を試して分かったこと — 段1 は今のところ通らない

2026-08-07、段1 を実際に書いた。`effect Trace` を
`entry/compiler/file_compile/file_compile.vibe` に置き、
load / type / bundle / parse / codegen に span を張り、codegen の中に
内部 span `dce` を1つ入れ、`--profile-tsv` の7要素タプルを span 表に
置き換えた。**stage2 のビルドは通ったが、CLI 本体
(`lib/@vibe/cli/main.vibex`) のコンパイルが落ちた。**

落としたのは handle 適格性検査 (`handle of effect 'Trace' cannot be
compiled here`, `inline_direct_perform.vibe`)。受理される callee の形の
実測表と現行の診断文は [cheatsheet](../../user/reference/cheatsheet.md) の
"A `handle` that type-checks can still fail to compile" 節にある。

**2つの配置を試して、両方拒否された:**

1. handler を `lib/@vibe/cli/dispatch.vibe` に置き、import した
   `compile_release_file_mode_traced` を包む
2. handler を perform の隣 (`file_compile.vibe` 内) に移し、**同一ファイルの
   named top-level `fn` を直接**包む

2 が包むのは named top-level `fn` — それ自体は適格な callee の形 — なのに
拒否される。つまり適格性は「handled body が直接呼ぶものの形」だけでは
決まらない: この検査は handle が覆う**すべての** perform を静的に追う必要が
あり、`compile_file_fs_mode_traced` の中で perform に挟まれて呼ばれている
`collect_source_groups_fs` / `prepare_file_fs_from_source_groups_persistent_cached` /
`compile_wasi_module` などのどれかが、追えない形 (row 無しの binding 経由・
row 変数付き callee) を含むためである。#2137 以降の診断は見えない呼び出しを
名指しする (犯人が依存モジュール側にあるときは位置は付かない、#1596)。

**これは §3 の結論を否定しない。** §3 が測ったのは effect 機構のコストで、
それは今も 5.4ns / アロケーションゼロ / row tax ゼロである。落ちたのは
**コンパイラという特定のコードベースの呼び出しグラフを migration が
追いきれない**という別の問題で、#1347-2 と同じ根 (資料 p133 の
evidence vector) を持つ。

したがって段1 の前提は「言語機能は既にある」から
**「言語機能はあるが、コンパイラの呼び出しグラフには適用できない」**に
変わる。次に決めるべきはどちらか:

- **(a) 適格性を広げる** — evidence migration が追える形を増やす。
  #1347-2 と同じ本体で、重い。
- **(b) span を適格な位置まで押し下げる** — perform と handler の間に
  何も挟まない粒度、つまり「大きな実行単位」より細かい単位に span を置き、
  各所で閉じる。ユーザ指定の粒度方針とは逆向きになる。
- **(c) 段0 (プロセス単位、ホスト側だけ) を先に出す** — コンパイラ内部に
  手を入れず、CI の多プロセス像だけ先に得る。§6 の段0 はもともと
  コンパイラ変更不要なので、これは今日できる。

実装は revert した。span を張った diff 自体は小さく機械的なので、
(a) が動いたときにそのまま再適用できる。

## 5.6 段0 着地 — 実際のビルドで測った

`scripts/trace_lib.sh` (sourceable) / `scripts/trace_span.sh` (コマンドラッパ) /
`scripts/trace_report.mjs` (木とクリティカルパスの描画) /
`scripts/test_trace_spans.sh` (回帰ロック)。`generations.sh` の
`run_generation_compile` に配線したので、bootstrap の各ステージが span になる。
**コンパイラは1行も変えていない。**

```bash
VIBE_TRACE_OUT=/tmp/build.ndjson bash scripts/trace_span.sh "selfhost build" \
  bash scripts/generations.sh build --out-dir /tmp/gen --stage3
node scripts/trace_report.mjs /tmp/build.ndjson
```

実行結果 (このマシン、`--stage3`):

```
trace 3406b42c66e0697373c6f021fc0b45c3  (4 spans)
     wall       self  name
 195977.0   94536.1  selfhost build
  32594.7   32594.7    stage0(seed) -> stage1
  35864.5   35864.5    stage1 -> stage2
  32981.7   32981.7    stage2 -> stage3

critical path:
  selfhost build (195977ms) -> stage2 -> stage3 (32982ms)
```

**196秒のビルドのうち 94.5秒 (48%) が、3つのステージコンパイルのどれにも
入っていない。** self 時間の列がそれを直接示している。中身は flat source の
準備・bundle 生成・検証で、これまで誰も測っていなかった — ステージの
コンパイル時間だけを見ていると存在自体が見えない。

これが段0 だけで出た。次に span を刻むべき場所は、この 94.5 秒の中である。

### 段0 の設計上の判断

- **無効時は string test 1回と `exec` だけ。** `VIBE_TRACE_OUT` 未設定で
  完全に no-op なので、内側のループに置いたままにできる。
- **1 span = 1行を終了時に1回だけ append。** begin/end の2行に分けない。
  並列 fan-out で複数プロセスが同じファイルに書くので、O_APPEND への短い
  単一 write に収めて行が裂けないようにしている。`trace_report.mjs` は
  それでも裂けた行を数えて報告する (黙って落とすと、木が完全であるかのように
  見えてしまう)。
- **不正な `VIBE_TRACEPARENT` は「無い」として扱い、新しい trace を始める。**
  伝播すると全 span が誤った trace の下にぶら下がり、分割されるより悪い。
- **`trace_begin` は値を echo せず変数に代入する。** `tok=$(trace_begin ...)`
  だと `export VIBE_TRACEPARENT` がサブシェルで起きて子に届かず、木が
  平らになる。回帰テストの3番目がこれをロックしている。
- **rc も記録する。** 失敗した span を落とすと、赤いビルドが短いビルドに見える。

### 5.7 バッテリ全体も1本のトレースになった

`unit_test_runner.sh` の `run_one` を span で包んだ。`xargs -P` の worker は
それぞれ別プロセスなので `VIBE_TRACEPARENT` を継承し、バッテリ span の下の
**きょうだい**として並ぶ。

```bash
VIBE_TRACE_OUT=/tmp/battery.ndjson bash scripts/trace_span.sh "unit battery" \
  bash scripts/unit_test_runner.sh
node scripts/trace_report.mjs /tmp/battery.ndjson --top 12
```

**541 span / 1トレース** (テストファイル538 + ステージ2 + root)。

```
 420893.2  272429.6  unit battery
  36676.3   36676.3    stage0(seed) -> stage1
  33271.7   33271.7    stage1 -> stage2
  ...

slowest 12 by self time:
 272429.6  unit battery
  46937.7  test lib/@vibe/compiler/tests/s5_wasm_test.vibe
  36676.3  stage0(seed) -> stage1
  33271.7  stage1 -> stage2
  24610.1  test lib/@vibe/compiler/tests/s5_entry_test.vibe
  12520.6  test lib/@vibe/compiler/tests/codegen_heap_e2e_test.vibe
   3256.7  test lib/@vibe/compiler/tests/module_loader_collect_sources_test.vibe
```

2つの読み:

1. **538ファイル中2つ (`s5_wasm_test` / `s5_entry_test`) で 71.5 秒**、
   3番目以降とは1桁違う。バッテリを速くする話はここから始まる。
2. **421秒のうち 272秒 (65%) が、どの子 span の中にもない。**
   §5.6 で bootstrap ビルドの 48% が同じように「どのステージにも入っていない」
   と出たのと同じ場所 — flat source の準備・bundle 生成・discovery・cache 暖機
   である。**2つの独立な計測が同じ穴を指している。**

> self 時間の読み方: 並列 fan-out では子の wall の**合計**は親を超えるので、
> `trace_report.mjs` は子の区間の**和集合**を引いている。したがって
> 「self = どの子 span も走っていなかった時間」であって、
> 「親自身の CPU 時間」ではない。

### 5.8 未帰属だった時間の正体 — span を1つ足しただけで出た

§5.6 と §5.7 が同じ「どのフェーズにも属さない半分」を指していたので、
`generations.sh` の bundle 生成呼び出しに span を1つ足した。

```
trace 7c36551f...  (4 spans)
     wall       self  name
 125120.0    1738.7  selfhost build
  76976.0   76976.0    prepare flat source
  22825.9   22825.9    stage0(seed) -> stage1
  23579.4   23579.4    stage1 -> stage2
```

**`prepare flat source` が 77.0秒 = ビルドの 62%。** そして root の未帰属
self 時間が **94.5秒 → 1.7秒**に落ちた。span 1つが、未説明だった時間の
ほぼ全部を回収している。

正体は `scripts/generate_bundle.sh` (1,211行の bash) だった。

**ただし「77秒の bash」は誤りで、span をもう1段刻んで訂正した。**
その中の `validate_module_source_compiles` は、生成した flat module source を
**seed で丸ごとコンパイルし直している** (`--invoke cli_main $seed_wasm
$candidate ...`) — bundle の帳簿仕事ではなく、ステージ hop と同じ実体の
コンパイルである。span を足すと:

```
trace ffa885f7...  (5 spans)
     wall       self  name
 115348.1    1144.8  selfhost build
  69674.4   48497.6    prepare flat source
  21176.8   21176.8      validate module source (seed compile)
  21890.1   21890.1    stage0(seed) -> stage1
  22638.8   22638.8    stage1 -> stage2
```

**このビルドはコンパイルを3回ではなく4回している** (`--stage3` なら5回)。
`validate module source` の 21.2秒は stage hop (21.9s / 22.6s) とほぼ同じで、
これは当然で、同じ規模の入力を同じ seed でコンパイルしているからである。
`generations.sh` のログにはこの4回目が現れない。

内訳の確定:

| | |
|---|---|
| bundle 組み立て (本当に bash) | **48.5秒** |
| 隠れた4回目のコンパイル | **21.2秒** |
| stage0→stage1 | 21.9秒 |
| stage1→stage2 | 22.6秒 |

**48.5秒の bash は、依然として単一項目としてビルド最大**である
(どの1回のコンパイルよりも長い)。一方 21.2秒の方は bash の問題ではなく
「同じものを4回コンパイルしている」という構造の問題で、対処法が違う
(#979 の sticky-failure guard として意図的に入っているので、消すかどうかは
その趣旨との兼ね合いになる)。

> **これは自分の主張の訂正でもある。** 1つ前の版でここに「77秒の bash」と
> 書いた。span を1段深く刻んだら 1/3 が別物だった。段0 が返してくれるのは
> 「どこが遅いか」であって「なぜ遅いか」ではない — 後者は次の span を
> 置いて初めて出る。

> この結果自体が段0 の投資回収の証拠になっている。§5.6 の時点では
> 「48% がどこかにある」としか言えず、その先は勘だった。span を1つ、
> 当たりを付けた場所に置いたら 1回の実行で確定した。

次に見るべきは残る 48.5秒の中で、`generate_bundle.sh` の bash ループが
何回サブプロセスを起こしているかである (`while IFS=$'\t' read` が3箇所、
最内で `sed`/`awk`/`printf` を呼ぶ形)。ここは vibe を一切書かずに
速くできる可能性が高い。

### 5.9 もう1段刻んだら「bash が遅い」は完全に間違いだった

§5.8 で 48.5秒を「本当に bash」と切り分けたが、その中に span を6つ置いたら
**自前の bash はほぼ残らなかった**。

```
trace 2ccd115c...  (11 spans)
     wall       self  name
 112912.0     989.1  selfhost build
  68675.0    1099.2    prepare flat source
   3848.2    3848.2      adapter bundle (pass 1)
  29401.9   29401.9      exact adapter merged source
    611.2     611.2      adapter module source
  23375.1   23375.1      validate module source (seed compile)
   3994.3    3994.3      adapter bundle (pass 2)
     23.4      23.4      runtime entry bundle
   6321.8    6321.8      compiler sources bundle
  21725.8   21725.8    stage0(seed) -> stage1
  21522.1   21522.1    stage1 -> stage2
```

`prepare flat source` の self は **48.5秒 → 1.1秒**。最大は
`build_exact_adapter_merged_source` の **29.4秒 = ビルド全体の26%** で、
中身は:

1. `bootstrap_merge_flatten_tool` — **merge-flatten 専用のコンパイラ wasm を
   ビルドする** (= もう1回のコンパイル)
2. その wasm を `--invoke cli_main` で走らせて flat merged source を作る

つまり**これも bash ではなくコンパイラ実行**である。

### 結論: ビルドは「3回のコンパイル」ではない

`generations.sh` のログは stage hop を3つ (`--stage3` なら4つ) しか出さないが、
実際に走っているコンパイラ実行はもっと多い:

| | 秒 | ログに出るか |
|---|---|---|
| merge-flatten tool のビルド + 実行 | 29.4 | **出ない** |
| validate module source (seed compile) | 23.4 | **出ない** |
| stage0 → stage1 | 21.7 | 出る |
| stage1 → stage2 | 21.5 | 出る |
| compiler sources bundle | 6.3 | 出ない |
| adapter bundle ×2 | 7.8 | 出ない |
| generate_bundle.sh 自身の bash | **1.1** | — |

**ログに出る2回のコンパイル (43秒) より、出ないコンパイラ実行 (53秒) の方が
長い。** ビルド時間を縮める話は「codegen を速くする」でも
「bash を速くする」でもなく、**「同じソースを何回コンパイルしているかを
減らす」**だった。

`adapter bundle` が pass 1 / pass 2 で2回走っている (3.8 + 4.0 = 7.8秒) のも
ここで初めて見えた。

### 自分の主張を2回訂正したことについて

- 版1: 「77秒の bash」→ 1/3 は隠れたコンパイルだった (§5.8)
- 版2: 「48.5秒の bash」→ **その 29.4秒もコンパイルだった** (本節)

段0 の span は「どこ」を返し、「なに」は返さない。2回とも、私は次の span を
置く前に「なに」を断定した。**span を置くコストは1回あたり数行で、
ビルド1回分の時間しかかからない。**推測する前に置いた方が速い。

### 5.10 §5.9 の上位2件を読んだ — どちらも重複、判断は不要

**(1) merge-flatten tool は毎回ゼロから作り直している (29.4秒)**

`build_exact_adapter_merged_source` は `bootstrap_merge_flatten_tool` を
**無条件で**呼ぶ。その中身は3パス:

| pass | 内容 |
|---|---|
| 1 | seed が live tree を flatten → `seed_merged` (コンパイラ実行) |
| 2 | `emit-module-source` で DCE → `seed_modsrc` (host vibe コマンド) |
| 3 | seed が `seed_modsrc` をコンパイル → `flatten_wasm` (コンパイラ実行) |

そのうえで本体が `flatten_wasm` を `cli_adapter.vibe` に対して走らせる。
**merged source 1本を得るのにコンパイラを4回叩いている。**

そして pass 3 の冒頭は `rm -f "$flatten_wasm"` である。成果物は
`_build/merge_flatten_compiler.wasm` に残るのに、**鮮度チェックが無く
毎回消して作り直す**。この tool は (seed wasm, compiler sources) の
純粋な関数で、どちらもハッシュできる — `scripts/ensure_generated.sh` が
生成物5点に対して既にやっているのと同じ形の fingerprint gate が入る。

**(2) adapter bundle を2回書いている (3.8 + 4.0 = 7.8秒)**

`write_adapter_bundle "" ""` を空引数で1回、あとで実引数でもう1回。
どちらも同じ `$OUT_ADAPTER` に書くので、**1回目の内容は捨てられる**。

1回目が要るのは chicken-and-egg のためと読める — `build_exact_adapter_merged_source`
が `cli_adapter.vibe` を flatten するとき、`cli_adapter_bundle.vibe` が
存在して import 解決できる必要がある。つまり**1回目は「在ること」だけが
要件で、中身は要らない**。フル bundle (bash の `echo` の山) を書く必要はなく、
最小の妥当な stub で足りるはずである。

両方とも「同じものを2回作っている」だけで、**安全側の重複を外す判断
(§5.9 の3件目、#979 の guard) とは性質が違う**。合計 ~37秒、ビルドの
約1/3。

> 本節は診断であって修正ではない。どちらも bootstrap の最も壊れやすい
> ところを触るので、fingerprint gate も stub 化も、着手するなら
> `pkf run full-gate` と fixpoint を毎回通しながら進める必要がある。

### 5.11 (1) を実装した — 28秒、出力はバイト一致

`bootstrap_merge_flatten_tool` に fingerprint gate を入れた。値は
**`ensure_generated.sh --print-fingerprint` を再利用**する — その fingerprint は
seed wasm・manifest・manifest が名指す全ソース・`generate_bundle.sh`・
自分自身をカバーしており、**この tool の入力集合とちょうど同じ**である。
2つ目のハッシュを書き起こさないのは、将来どちらかに入力が足された時に
もう片方が黙って取りこぼすのを防ぐため。1.3秒。

| span | cold | warm | 差 |
|---|---|---|---|
| `exact adapter merged source` | 32,474 ms | **4,289 ms** | **-28.2s** |
| `prepare flat source` | 71,790 ms | 42,140 ms | -29.7s |

検証:

- **fixpoint OK** (`stage2 == stage3`)
- **cold ビルドと warm ビルドの stage2 がバイト一致** — キャッシュした tool が
  作り直した tool と同じ出力を出すことの直接の確認。これが一致しない限り
  この最適化は成立しない
- `pkf run test` 通過

安全側の設計:

- stamp は wasm が**実際に落ちた後**にだけ書く。失敗したビルドが
  「無い / 半端な tool」を fresh と印付けない
- fingerprint が読めなかった (空) ら**素通しで再ビルド**する。
  キャッシュは最適化であって、stale な tool を使う理由になってはならない
- 冒頭で `rm -f "$stamp"` — wasm を消して stamp を残す窓を作らない

## 6. Implementation order

| stage | content | compiler change | state |
|---|---|---|---|
| 0 | `VIBE_TRACEPARENT` propagation plus one NDJSON span per process, host side only | none | **implemented** (§5.6–§5.11): stage hops in `generations.sh`, the flat-source preparation in `generate_bundle.sh`, one span per file in `unit_test_runner.sh`, and per-document / per-block spans in the doctest fan-out (`doctest_extract_run.sh`) |
| 1 | `effect Trace` in a contract, replacing the 7-tuple plumbing of `--profile-tsv` with performs | yes | **blocked**: the attempt in §5.5 was rejected by the handle-eligibility check and reverted. It needs the eligibility check to follow the compiler's call graph, or spans pushed down to positions it accepts |
| 2 | `vibe bench` reports a span breakdown per bench block | yes (runner) | not started |
| 3 | the scoped `span {}` syntax (the desugaring of §2.2, at the same layer as `throw` → `perform Exception::Throw`) | yes (parser/desugar only) | not started |
| 4 | an OTLP exporter | none | not started |

Stage 0 alone pointed at two specific places to work on: two of 538 test files
take a sixth of the battery (§5.7), and both the bootstrap build and the
battery spent about half their time outside any phase (48% in §5.6, 65% in
§5.7), which §5.8–§5.11 traced to repeated compiler runs inside the bundle
generation.

## 7. この設計が引き受けていないこと

- **サンプリングプロファイラの代わりにはならない。** span は人が置いた境界しか
  見ない。`array_empty` が 4.3% であることは `--cpu-prof` が見つけたもので、
  span 木では (誰かがそこに span を置かない限り) 見えない。両方要る。
- **`bytes_per_op` は置き換えない。** bench の bytes/op は bump 高水位の差分で
  決定的な数値であり、ゲートに使える。span の heap delta はその内訳である。
- **span の粒度は人が決める。** 段1 でどこに span を置くかはこの文書では
  決めていない (フェーズ境界から始めるのが自然)。


## 8. Documents that disagree with the measurements

Writing the probes turned up places where a document or comment did not match
what the compiler does. Two are still open:

1. **The handle-arm separator is not documented in the cheatsheet.** The arms of
   a handler are separated by `;` or a newline, not `,`. A `,` is a parse error
   that names the edit (``replace this `,` with `;` …``, located at the comma
   since #3072), but the cheatsheet's examples all have a single arm, and its section
   "The separator depends on the context" lists match arms (`,`) and declaration
   members (`;`) without mentioning handler arms.
2. **ADR-0076's opening still describes the replay implementation as current.**
   Its row in [adr.md](../design/adr.md) begins with the pre-Phase-3 replay
   design ("現行の `handle` は replay 実装 …"), which ADR-0076 addendum 34 V2
   physically deleted. A stale comment of the same kind remains in
   `codegen/gc/backend_call_named_1.vibe` ("Algebraic (user-effect) performs need
   the replay-memo machinery and are not ported yet"). These are where the
   mistaken belief that wasm-gc cannot run user effects comes from; the
   corresponding comment in `codegen/gc/backend_expr.vibe`'s `EHandle` arm has
   already been corrected.
