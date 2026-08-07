# 内部 Span トレーシング設計 (提案)

`vibe bench` / `--profile-tsv` / `node --cpu-prof` が今それぞれ別々に答えている
「どこに時間とメモリが行ったか」を、**1つのネストしたスパン木**に統合するための
設計。将来 OpenTelemetry へ写せる形を最初から意識する。

これは提案であり、まだ実装されていない。実装順は §7。

## 1. 現状の計測手段と、それぞれが答えられないこと

| 手段 | 答えられること | 答えられないこと |
|---|---|---|
| `vibe bench` | `bench {}` ブロック単位の ns/op・bytes/op | ブロックの**内訳** |
| `--profile-tsv` / `VIBE_PROFILE_TSV` | ハードコードされた7ステージの経過時間 | その7つ以外・ネスト・モジュール単位・**メモリ** |
| `node --cpu-prof` | wasm 関数の self 時間 | アロケーション量。node runner 限定 (`vibe bench` は wasmtime) |
| `Profiler::now_us` / `heap_bytes` | 任意の1区間 | 手で配線する必要がある (後述) |
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
(`compile_release_file_mode` / `compile_release_file_mode_profiled`,
`selfhost_cli_low_level_args` / `..._profiled`)。計測を足すたびに分岐が増える。

### 1.2 実測で見えた、今の計測では詰められない例

2026-08-07 に取り直した実測 (`docs/perf-snapshot-2026-08-07.md`):

- **`array_empty` が CPU の 4.3%** (227ms/5.32s)。しかし「どのフェーズが空配列を
  作っているか」「その配列が最終的に何要素になるか」は今の手段では取れない。
  前者はフェーズ span の heap delta、後者はカウンタ属性で出る。
- **selfcompile heap 高水位が baseline 比 +8.5%** (1,167,101,072 vs
  1,075,701,656)。**どのフェーズが太ったかを示すものが何もない。**
  `bench/perf/heap_baseline.txt` は173行あり、そのうち172行は
  「なぜ増えたか」を人間が後から調べて書いた散文である。フェーズ単位の
  heap delta が同じスナップショットに入っていれば、この散文の大半は
  データで置き換えられる。

## 2. ゲスト側の表面

capability builtin の綴り規約 (`Effect::snake_case`、`perform` 不要 —
CLAUDE.md / ADR-0084) に従う:

```
Trace::span_begin(name: String) -> Int     // span handle
Trace::span_end(id: Int) -> Unit
Trace::span_attr(id: Int, key: String, value: String) -> Unit
Trace::event(name: String) -> Unit         // 幅ゼロのマーカー
Trace::enabled() -> Bool
```

ただし**素の begin/end を書かせるのが目的ではない**。狙いはスコープ構文:

```vibe
fn typecheck_module(path: String) -> TypeEnv with Fs + Trace {
  span "typecheck" {
    Trace::span_attr_here("module", path)
    ...
  }
}
```

`span name { body }` は begin/end に desugar し、**end は throw 経路でも走る位置**に
置く (`handle` の finally 相当)。

これが §1.1 のタプル配線と決定的に違う点は、**戻り値の型が変わらない**ことである。
`compile_release_file_mode_profiled` とその7要素タプルは消え、
`compile_release_file_mode` の row に `Trace` が付くだけになる。

### 2.1 row が伝播することの扱い (要判断)

span を開く関数の row に `Trace` が乗り、呼び出し側へ伝播する。これは
「権限が見える」という言語設計どおりの挙動だが、コストでもある: checker や
codegen の内部に span を1つ足すと、そこから CLI までの署名が変わる。

- **(a) 受け入れる** — row が「どこが計測対象か」のドキュメントになる。
- **(b) entry で1回だけ渡す** — `Profiler` が今まさにこの形で、
  `cli_main` / `selfhost_cli_dispatch_args` の row に既に入っている。

現状 `Profiler` は CLI 層までしか届いておらず、**面白い span があるのは
checker/codegen の内側**なので、この判断は先送りできない。
推奨は (b) 寄り: `Trace` を entry で1回付与し、span を開く十数個の関数について
row の増加を明示的なコストとして受け入れる。

## 3. 無効時のコスト

ホットパスに span を残すには、無効時がほぼゼロでなければならない。

ホスト import 呼び出しは span ごとに ~50-100ns かかるので、
「無効なら host が 0 を返す」では 100万 span で 0.1s 払うことになる。

代わりに**ゲスト側の i32 global** (`__trace_enabled`) を init 時に1回だけ
`Trace::enabled()` から立て、`span` の desugar が
`if __trace_enabled { ... }` で包む。無効時のコストは global.get + 分岐の ~1ns。
coverage 計装が既に使っている手口と同じ。

## 4. データの置き場所 — ring buffer、span ごとの host call ではなく

span ごとにホストを呼ぶのではなく、**linear memory 上の ring buffer に書き、
ホストが吸い出す**。既存の `vibe.trace` custom section
(`linked_compile.vibe:3441` がメモリ領域とカウンタを予約している) と同じ構造で、
そのまま拡張できる。

固定32バイトのレコード:

```
[0..4)   u32 span_id
[4..8)   u32 parent_id
[8..16)  u64 t_ns          -- ホストクロック
[16..24) u64 heap_ptr      -- そのイベント時点の bump 高水位
[24..28) u32 name_id       -- コンパイル時に埋めた静的文字列表への添字
[28..32) u32 kind/flags    -- begin | end | event
```

**name を コンパイル時に intern するのが安さの鍵**: `span "typecheck"` の名前は
リテラルなので、codegen が文字列表に入れて添字だけ渡せる。動的な属性
(モジュールパス等) は別の遅い側チャネルに置き、opt-in にする。

`heap_ptr` を **すべてのレコードに入れる**のが、この設計が既存手段に対して
持つ最大の追加価値である。時間だけなら `--cpu-prof` でも取れるが、
**アロケーションを区間に帰属させる手段が今どこにもない**。

## 5. 分散トレーシングへの写像

上のレコードは OTel span の部分集合になるように選んである。

| vibe | OTel |
|---|---|
| `name_id` → 文字列 | `name` |
| `t_ns` (begin/end 対) | `startTimeUnixNano` / `endTimeUnixNano` |
| `(process_id, span_id)` | `spanId` (64bit) |
| `parent_id` / 親プロセスの span | `parentSpanId` |
| `VIBE_TRACEPARENT` (W3C traceparent) | `traceId` (128bit) |
| `heap_ptr` の差分 | attribute `vibe.heap_bytes` (OTel に標準の枠がない) |

プロセス間の親子は **W3C traceparent を環境変数で渡す**:
子プロセスは `VIBE_TRACEPARENT=00-<trace_id>-<parent_span_id>-01` を受け取り、
自分の root span をその下に付ける。

### 5.1 なぜこれがこのリポジトリで効くか

ビルドは**既に多プロセスの木**であり、現在の道具はそれを1つのものとして見られない:

- `scripts/generations.sh build` = seed → stage1 → stage2 → stage3、別プロセスで4回のフルコンパイル
- `scripts/unit_test_runner.sh` は数百のコンパイル+実行プロセスに fan-out
- doctest の fan-out (#819)、`parallel_warm_pool.sh`

今 CI バッテリの内訳を知るには shard ごとの `wall_ms` を bash で足し合わせる
しかなく、`docs/ci-speed.md` は実際にその手作業で書かれている。
traceparent 伝播があれば1回の run が1本のトレースになり、クリティカルパスが
そのまま出る。**これは §7 で最初に実装すべき部分でもある** — コンパイラを
1行も変えずに実現でき、価値が大きい。

## 6. 出力形式

`VIBE_TRACE_OUT` が指すファイルへ NDJSON を1行1レコードで書く:

```json
{"tid":"<32hex>","sid":"<16hex>","pid":"<16hex>","name":"typecheck",
 "t0":123456,"t1":789012,"heap0":1024,"heap1":8192,"attrs":{"module":"..."}}
```

OTLP-protobuf をここで採らないのは意図的: 依存が要らず、grep でき、`jq` で
集計できる。Jaeger/Tempo に向けたくなった時点で ~100行の変換器を足せばよい。

## 7. 実装順

| 段 | 内容 | コンパイラ変更 |
|---|---|---|
| 0 | `VIBE_TRACEPARENT` 伝播 + ホスト側だけで1プロセス1 span の NDJSON 出力 (`run_wasm_vibe_host_runner.sh` / `unit_test_runner.sh` / `generations.sh`) | **不要** |
| 1 | `Trace::span_begin/end` host import + ゲスト ring buffer + `span {}` 構文。`--profile-tsv` の7タプル配線を span へ置き換え、TSV は span 木から生成して `test_cli_core.sh` 互換を保つ | 要 |
| 2 | `vibe bench` が bench ブロックごとに span 内訳を出す (1行の ns_p50 を開ける) | 要 |
| 3 | OTLP エクスポータ | 不要 |

段0だけで CI の多プロセス像が取れ、段1で §1.1 の二重関数が消える。
段2が「`vibe bench` 自体が取れるデータを良くする」という当初の目的に直接答える。

## 8. この設計が引き受けていないこと

- **サンプリングプロファイラの代わりにはならない。** span は人が置いた境界しか
  見ない。`array_empty` が 4.3% であることは `--cpu-prof` が見つけたもので、
  span 木では (誰かがそこに span を置かない限り) 見えない。両方要る。
- **`bytes_per_op` は置き換えない。** bench の bytes/op は bump 高水位の差分で
  決定的な数値であり、ゲートに使える。span の heap delta はその内訳であって、
  精度は同じでも粒度が細かいぶんノイズ源も増える。
- **row の伝播 (§2.1) は未決。** ここを決めずに段1を始めると、checker 内部に
  span を置いた瞬間に大量の署名変更が発生する。
