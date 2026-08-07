# Perf snapshot 2026-08-07 — 実測、ボトルネック、メモリ削減候補

`main@dcee5fa1` から `scripts/generations.sh build` した stage2 に対する実測。
すべて同一の 4-core / 16GB マシン、無負荷で取得。

再現手順:

```bash
bash scripts/generations.sh build --out-dir /tmp/gen
bash scripts/selfcompile_kpi.sh /tmp/gen/stage2.wasm            # heap / wall
VIBE_WASM_NAMES=1 bash scripts/generations.sh build --out-dir /tmp/namedgen
scripts/profile_compile.sh /tmp/namedgen/stage2.wasm lib/@vibe/compiler/tests/codegen_lexer_test.vibe 30
```

## 1. selfcompile KPI

| 項目 | 値 |
|---|---|
| heap_ptr_bytes (cold cache) | **1,167,101,072** |
| `bench/perf/heap_baseline.txt` | 1,075,701,656 |
| 差 | **+8.50%** (ゲートは +10% で落ちる) |
| mem_pages | 18,663 (= 1,223 MB linear memory) |
| wall_ms (3回: 5577 / 7759 / 8319) | median 7,759 |

**ゲートの残り余裕は 1.5%。** これは初めてではない — `heap_baseline.txt` の
過去 rebaseline 記録 (2026-07-20 / 07-24 / 08-01) はいずれも「PR のせいではなく
main 側で溜まったドリフトが帯を食い尽くしていた」と書いている。同じことが今また
起きている。

## 2. CPU プロファイル

`node --cpu-prof` で実コンパイル1回 (`codegen_lexer_test.vibe`, full closure)。
cpu total 5.32s / wall 5,732ms。

### 2.1 self 時間 上位

```
   357.8ms  6.7%  __rt_arr_new
   352.1ms  6.6%  __rt_eq
   290.2ms  5.5%  __rt_arr_get
   256.1ms  4.8%  __rt_arr_push
   221.7ms  4.2%  __rt_str_eq
   214.9ms  4.0%  __rt_str_char_code_at
   186.6ms  3.5%  compact_string_fingerprint  (lib/@vibe/cache/cache.vibe)
   161.0ms  3.0%  str_lt                      (lib/@vibe/compiler/core/sorted_index.vibe)
   159.8ms  3.0%  __rt_arr_slice
```

上位6つがすべてランタイムプリミティブで、合計約32%。**単独の O(N²) スキャンが
支配する形ではなく、配列/文字列操作に一様に律速されている。**

### 2.2 ランタイム時間を直近のユーザ関数に帰属させた表

(`__rt_*` / `HashMap::*` フレームを、呼び出し元の最も近いユーザ関数へ寄せたもの)

```
   252.0ms  4.7%  str_lt@compiler/core/sorted_index
   227.2ms  4.3%  array_empty@core/array
   208.2ms  3.9%  compact_string_fingerprint@cache/cache
   200.2ms  3.8%  array_contains_str@codegen/common_extractors
   120.0ms  2.3%  collect_strings_expr@codegen/common_analysis
   116.5ms  2.2%  env_lookup@compiler/core/types
    94.7ms  1.8%  rewrite_alias_expr_ix@core/import_alias_rewrite
    91.6ms  1.7%  edp_collect_handle_sites_expr@codegen/common_base/inline_direct_perform
    85.8ms  1.6%  bsearch_leftmost@compiler/core/sorted_index
    77.7ms  1.5%  pc_count@compiler/perceus
    50.2ms  0.9%  dce_array_contains_str@core/dce
```

## 3. メモリ削減候補

### 3.1 【実測済み・最大】配列のデフォルト容量 8 が過大

`array_empty()` は `ArrayBuilder::freeze(ArrayBuilder::new())` で、
`ArrayBuilder::freeze` は identity、`ArrayBuilder::new` は `__rt_arr_new`。
非RC (bump) レーンの `gen_arr_new_body`
(`codegen/builtin_bodies/bodies_core_a1a2.vibe`) は

```
12 バイトのヘッダ + 8 スロット × 8 バイトのインラインバッファ = 76 バイト
```

を bump する。bump アロケータは解放しないので、**1要素も入らなかった空配列も
76 バイトを恒久的に占める**。`array_empty()` の呼び出し箇所はコンパイラソース中に
**1,953 箇所**ある。

デフォルト容量を変えた stage2 を実際にビルドして cold-cache KPI を測った:

| デフォルト容量 | bump サイズ | heap_ptr_bytes | 現行比 | wall median (5回) | wall min |
|---|---|---|---|---|---|
| 8 (現行) | 76 B | 1,167,101,072 | — | 6,943 ms | 5,291 ms |
| 4 | 44 B | 1,051,249,096 | **-9.93%** | 5,277 ms | 5,015 ms |
| 2 | 28 B | **1,005,293,432** | **-13.86%** | 5,311 ms | 5,106 ms |

**容量 8 → 2 で selfcompile の heap 高水位が 13.9% 下がる。** ソースは1行も
変えておらず、生成される runtime helper の初期容量だけの違い。
1,005,293,432 は現行の committed baseline (1,075,701,656) より 6.5% 低い。

wall については **median と min を分けて読む必要がある**。min 同士では
5,291 → 5,106 ms (-3.5%) と小さいが、median は 6,943 → 5,311 ms (-23%)。
cap 8 の5回は 5291..8448 とばらつき、cap 4/2 は 5015..5798 に収まっている。
つまり効いているのは**素の速さではなく裾の縮小**で、1.2GB まで伸びる
linear memory の grow / ページフォルトが cap 8 側の遅い実行を作っていた、
という読みと整合する。

`4 → 2` でも heap がさらに 4.4% 減り wall は変わらないので、
**配列の大半は2要素以下**である。

トレードオフは再確保である。成長は `newcap = cap * 2`
(`bodies_core_a1b.vibe:232`) で、非RC レーンでは古いバッファを解放せずに
`newcap*8` バイトを新しく bump する。したがって最終長 L の配列のコストは

- `L <= cap`: `12 + cap*8`
- `L > cap`: `12 + cap*8 + 8*(2cap + 4cap + ...)`

つまり **配列の最終長の分布**で決まる。コンパイル全体で 13.9% 減ったという
事実は、集計として「大半の配列が短い」を意味している。

**ただしこれは場所によらず真ではない。** `lex_checker_vibe` の bytes_per_op は
cap 8 でも cap 2 でも **2,198,112 でバイト単位で一致する** (両方とも
`VIBE_BUILD_CACHE_DIR` を分離した cold cache で測定 — キャッシュのこだまでは
ない)。レキサのトークン配列は初期容量に関係なく 8 をはるかに超えて伸びるので、
初期容量が何であっても同じところに着地する。効いているのは
parse/check/codegen が撒く大量の短い配列 (AST ノードの params / args /
fields) の方である。

> 「配列の最終長の分布」そのものは今のツールでは取れず、上の結論は
> 3点の A/B から逆算した推測にとどまる。これは
> [docs/tracing-design.md](tracing-design.md) が埋めようとしている穴の実例で、
> span の属性としてカウンタを持てれば推測ではなく実測になる。

### 3.2 フロントエンドのアロケーション密度

`vibe bench` の bytes/op から (対象: `lib/@vibe/compiler/checker/checker.vibe`,
325,733 バイト):

| 段 | ns_p50 | bytes/op | ソース1バイトあたり |
|---|---|---|---|
| lex のみ | 14.54 ms | 2,198,112 | 6.7 B |
| parse のみ (トークン→AST) | 16.42 ms | 2,429,360 | 7.5 B |
| lex + parse | 31.18 ms | 4,627,472 | **14.2 B** |

**ソース1バイトを AST にするのに 14 バイト確保している。** §3.1 の容量修正は
ここにも直接効く (AST ノードが持つ params / args / fields の配列は大半が空か
数要素)。

## 4. CPU ボトルネック候補

### 4.1 `String::char_code_at` が1文字ごとの関数呼び出し

`gen_str_char_code_at_body` (`bodies_core_b.vibe:1351`) は境界チェック付きの
**アウトオブライン wasm 関数**。`__rt_str_char_code_at` 単体で self 4.0%。

これを1文字ずつ呼んでいるのが:

- `str_lt` (`core/sorted_index.vibe:23`) — 4.7%。1文字ずつ比較するループ
- `compact_string_fingerprint` (`cache/cache.vibe:19`) — 3.9%。全ソースの全文字を走査

**合計 8.6% がこの2関数に集中しており、その大半は「1文字ごとに関数を呼んで
境界チェックしている」オーバーヘッドである。** 両者ともランタイムヘルパ
(`__rt_str_lt` / `__rt_str_hash`) として1つの wasm 関数の中でメモリを直接
舐める形に落とせば、呼び出しと境界チェックが消える。

`str_lt` が char 単位なのは意図的で、CLAUDE.md に記録がある —
MoonBit の `String <` が length-first で `"buf" < "acc_bits"` を true にしたため
自前の lexicographic 比較を書いた。その判断は正しいが、**実装が今いちばん熱い
ユーザ関数になっている。**

### 4.2 残っている線形スキャン

`array_contains_str@codegen/common_extractors` 3.8% +
`dce_array_contains_str@core/dce` 0.9% = 4.7%。#1259 でいくつかの
scan→hash-index 変換をしたが、この2つは残っている。ただし #1321 の
rebaseline 記録が示すとおり、**インデックス化は heap を増やす方向のトレードオフ**
(あのときは -10..-16% CPU と引き換えに +16MB) なので、§3.1 の余裕を作ってから
やるのが順序として正しい。

## 5. ベンチ側で見つかった不具合

**`lexer_bench.vibe` の 5 系列のうち 2 つが空のシムを測っている。**

`lexer_hotspot_probe.vibe` は

- `probe_lex_lexer_vibe` → `lib/@vibe/compiler/syntax/lexer.vibe` (**350 バイト**)
- `probe_lex_parser_vibe` → `lib/@vibe/compiler/syntax/parser.vibe` (**399 バイト**)

を読んでいるが、この2ファイルは #753 (ADR-0065 Phase 3) で
`@vibe/parser` パッケージへの **re-export シム**になっている。実体は
`lib/@vibe/parser/lexer.vibe` (44,116 バイト) / `parser.vibe` (47,443 バイト)。

測定値がそれを裏付けている:

```
lex_lexer_vibe    ns_p50=11,380      bytes_per_op=1,320
lex_parser_vibe   ns_p50=13,378      bytes_per_op=1,480
lex_checker_vibe  ns_p50=14,535,579  bytes_per_op=2,198,112
```

同じ `lexer_hotspot_probe.vibe` の中で `parser_hotspot_probe.vibe` の方は
実体パス (`lib/@vibe/parser/lexer.vibe`) を読んでおり、そちらは
`parse_lexer_vibe ns_p50=5,455,266` と妥当な値を出している。
**片方だけ #753 の移動に追随できていない。**

これは compiler-perf-profiling スキルが「bench の罠」として明示的に警告している
ケースそのもの (「~80µs など不自然に速い数字は corpus を疑う」)。
修正は probe のパス2つを差し替えるだけ。

## 6. 優先順位の提案

| # | 施策 | 効果 | 確度 |
|---|---|---|---|
| 1 | 配列デフォルト容量 8 → 2 (§3.1) | heap **-13.9%**、wall の裾 -23% | **実測済み (要検証、下記)** |
| 2 | `lexer_hotspot_probe` のシム参照を修正 (§5) | 2系列が意味を持つ | 確実 |
| 3 | `__rt_str_lt` / `__rt_str_hash` ランタイムヘルパ (§4.1) | CPU 最大 -8.6% | 推定 |
| 4 | 残る線形スキャンのインデックス化 (§4.2) | CPU -4.7%、heap は増える | 推定 |

1 と 2 は独立して小さく、1 は heap ゲートの余裕を +1.5% から +6.5% 下 (=
ratchet down 後に約 +10% の帯) へ戻す。

### 1 の検証状況

| 検証 | 結果 |
|---|---|
| `stage2 == stage3` fixpoint | **OK** (`generations.sh build --stage3` + `cmp`) |
| ユニットテストバッテリ | **537/537 ファイル pass** |
| `scripts/size_ratchet.sh` | **全サンプル +2% 以内** |
| `bench/perf/heap_baseline.txt` | 1,005,293,432 へ ratchet down 済み |
| RC レーン (`enable_rc`) | **未着手 — 容量8のまま**。free-list がサイズクラスで再利用するので同じ向きに効く保証がなく、別途測る |
| KPI 入力以外のワークロード | **未測定**。長い配列を大量に作るプログラムでは再確保が増える方向 |
