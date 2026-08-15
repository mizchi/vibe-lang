# 生成コードサイズ: linear backend vs wasm-gc backend

測定日: 2026-08-15 / 測定コミット: `9242ae9b0` / 再現: `bash scripts/measure_backend_code_size.sh`

関連: [gc-value-abi.md](./gc-value-abi.md) (#1331), [feature-levels.md](./feature-levels.md),
[../BENCHMARKS.md](../BENCHMARKS.md) (linear レーンの時間方向の回帰シグナル)

## 結論

**小さいプログラムでは wasm-gc の方が大きい。交点は linear 出力で約 35 KB。**

wasm-gc レーンは **固定 4 KB のランタイムプレリュードを、コード 1 バイトあたり
約 6% の節約で償却する**形になっている。fixture / bench 規模のプログラムは
ほぼ全部が償却前の領域にいるので、そこだけ測ると「gc は 5 倍でかい」と読める。
実アプリ規模 (数十 KB 以上) でようやく数 % 縮む。

「wasm-gc にすればビルドサイズが減る」は**現状では成り立たない** — 減る領域は
実在するが、今このリポジトリが出している成果物はそこに届いていない。

## 実測

同一ソースを両バックエンドでコンパイルした `.wasm` のバイト数。ケースセットは
`bench/binary_size/` (#1056) をそのまま使っており、[../BENCHMARKS.md](../BENCHMARKS.md)
の linear 側の数字と同じ土俵に乗る。`result` 列は両レーンの実行結果で、これが
一致しない行はサイズ比較としても無効 (壊れた wasm は小さくて当たり前なので、
サイズと必ず一緒に見る)。

| プログラム | 主に効く形 | linear | wasm-gc | Δ | 実行結果 |
|---|---|---:|---:|---:|---:|
| `empty` | `() -> 0` (固定費の対照) | 742 | 4,831 | +551.1% | 0 |
| `hello_world` | 単一 `println` | 831 | 4,877 | +486.9% | 0 |
| `fib` | 再帰呼び出し | 795 | 4,875 | +513.2% | 6765 |
| `fizzbuzz` | ループ + 条件分岐 | 1,384 | 5,008 | +261.8% | 0 |
| `closure_indirect` | 高階関数 / 間接呼び出し | 2,456 | 5,095 | +107.5% | 31 |
| `variant_float` | 代数型 match + 浮動小数 | 4,459 | 5,743 | +28.8% | 31 |
| `scaled10` | 合成 ×10 | 7,154 | 8,821 | +23.3% | 105 |
| `scaled40` | 合成 ×40 | 19,949 | 20,699 | +3.8% | 255 |
| `scaled80` | 合成 ×80 | 37,084 | 36,595 | **−1.3%** | 455 |
| `scaled160` | 合成 ×160 | 71,324 | 69,238 | **−2.9%** | 855 |

`empty` は既存ケースセットに無いので測定スクリプト側で生成している —
最小の `hello_world` ですら `println` を呼ぶので、「何も使わないプログラム」を
別に置かないと固定費そのものが取れない。

`scaledN` は「struct 定義 + 射影 + 配列確保ループ + 文字列構築」を 1 セットと
して N コピー並べた合成ソース。既存ケースセットは固定サイズなので傾きが取れず、
交点 (この測定の主結論) はこちらでしか出せない。

```
slope:     linear 427.8 B/copy, wasm-gc 402.8 B/copy (gc = 94.2% of linear)
intercept: linear 2876 B, wasm-gc 4793 B (fitted, NOT the empty-program size)
residual:  max 421 B off the fitted line (0.6% of the largest point)
crossover: 77 copies == 34.8 KB of linear output
```

残差 0.6% なので、この範囲では線形近似そのものは妥当。

> **fitted intercept は空プログラムのサイズではない。** 直線の切片 (2,876 /
> 4,793) は `empty` の実測 (742 / 4,831) と一致しない。合成ソースは 1 コピー目
> から `ArrayBuilder` / `StringBuilder` を使うので、linear 側は「使ったときだけ
> 出る」ヘルパを切片に含んでいる一方、gc 側は元から全部出しているので増えない。
> 両者を混ぜて引き算しないこと — **固定費の実測は `empty` の行、傾きは
> `scaled*` の行**で、切片は交点を出すための中間量でしかない。

## なぜこうなるのか

セクション単位・関数単位に分解すると理由は 1 つに絞れる
(`node scripts/wasm_section_sizes.mjs <file.wasm>`)。

| | `empty` linear | `empty` gc | `closure_indirect` linear | `closure_indirect` gc |
|---|---:|---:|---:|---:|
| code セクション | 428 | 4,577 | 2,116 | 4,815 |
| type セクション | 54 | 76 | 67 | 89 |
| func セクション | 66 | 49 | 69 | 52 |
| 関数の数 | 65 | 48 | 68 | 51 |
| うち本体 4 B 以下のスタブ | **61** | 2 | **54** | 1 |
| 本体を持つ関数 | 4 | **46** | 14 | **50** |

**gc レーンは 200〜313 B のランタイムヘルパを、使う使わないに関係なく無条件に
吐く。** `empty` と `closure_indirect` の gc 側で上位関数サイズの並び
(313, 302, 236, 236, 216, 207, 205, 199, …) が完全に一致することがその証拠で、
プログラムが何をしようと同じ本体が入っている。48 本中スタブは 1〜2 本しかない。

**linear レーンは同じスロットを持ちながら、使われた本体だけを埋める。**
空プログラムでは 65 関数のうち 61 本が 4 B 以下のスタブで、コードセクション
全体が 428 B しかない。間接呼び出しを使った途端に 7 本のスタブが実体に変わり
(646 / 285 / 214 / 207 B …)、ユーザ関数 3 本と合わせて本体を持つ関数が 4 → 14 本、
コードは 2,116 B に膨らむ。

つまり **linear は必要になるまで払わない / gc は先に全部払う**。gc の固定費が
+4,089 B なのはこれで、これが交点の分子になる。

分母 (傾きの差) の方はずっと小さい。`scaled160` で見ると:

- code セクション: linear 70,183 → gc 66,393 B (**−5.4%**)
- type セクション: linear 67 → gc 1,050 B (nominal struct 型を型セクションに宣言する分)
- func セクション: linear 868 → gc 1,653 B (型インデックスが増えて LEB が伸びる)

コード本体では gc が勝つが、その利得の一部を型メタデータで返している。差し引き
1 コピーあたり 25 B (427.8 − 402.8) しか稼げないので、4,089 B の固定費を返すのに
77 コピー = 約 35 KB かかる。

## 測定方法と落とし穴

```bash
bash scripts/measure_backend_code_size.sh [stage2.wasm]
MEASURE_SCALES="10 20 40 80" bash scripts/measure_backend_code_size.sh
node scripts/wasm_section_sizes.mjs _build/backend_code_size/empty.gc.wasm
```

再測定するときに踏みやすいものが 2 つある。どちらも**黙って誤った数字を出す**
種類の失敗なので、結果の形で気づけるようにしておくこと。

**1. `VIBE_FS_COMPILE=1` を付けると gc レーンは無効になる。** gc backend は
direct source compile 専用で、FS-import モードと特殊な instrumentation モードは
linear 固定である (`cli_adapter` のコメント)。両方に付けて測ると
**両レーンがバイト単位で一致する** — これは「差が無い」ではなく「両方 linear を
測った」なので、一致を見たらまずこれを疑う。この制約の帰結として、**ここで
測れるのは import を持たない単一ファイルだけ**であり、実アプリの実測ではなく
傾きの推定である。

**2. entry 名は `main` にする。** doctest 等が使う `__no_entry__` sentinel は
linear では通るが gc では `entry function not found: __no_entry__` で落ちる。
gc 側だけ 0 バイトになるので気づける形ではあるが、`|| true` で握り潰すと
「gc は 0 B」という無意味な勝利になる。スクリプトは 0 バイトをサイズ表に混ぜず
COMPILE FAILED として報告する。正しい呼び出し形は `scripts/compiler_gate.sh` の
40h (wasm-gc backend smoke) と `scripts/bench_binary_size.sh` と同じ。

## この数字をどう使うか

- **gc レーンをサイズ目的で選ぶ理由は現状ない。** 選ぶ理由は
  [gc-value-abi.md](./gc-value-abi.md) にある表現の方 (ネイティブ参照、循環構造の
  回収、RC の除去) であって、サイズは副作用ですらない。
- **固定費を削る方が交点を近づける効果がはるかに大きい。** 4,089 B の無条件
  プレリュードを DCE できれば交点はほぼ消える。傾き側 (6%) をいくら改善しても
  交点は動きにくい。gc レーンにも linear と同じ「スロットは置くが、使われた
  本体だけ埋める」機構を入れる、というのが最も直接的な改善になる。
- **サイズ回帰を見張るなら linear 側で見る。** gc は固定費が支配的で、ユーザ
  コードの増減が数字にほとんど出ない (`closure_indirect` は linear で
  +1,714 B、gc では +264 B)。回帰検出器としては鈍すぎる。
