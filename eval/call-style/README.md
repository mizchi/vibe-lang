# call-style — 呼び出し表記の可読性評価

#1189 (UFCS を入れるか、`Array::push(arr, x)` を `arr.push(x)` と書けるようにするか)
の判断材料を、AI リーダー(subagent)に実際にコード片を読ませて集める評価ループ。
`eval/lang-review/` (言語全体の rubric レビュー) や `eval/msr/` (改修生存率) とは別軸:
こちらは **「3つの呼び出し表記のうち、どれが最も少ない前後文脈で正しく意味を復元できるか」**
だけに絞った狭いミクロベンチマーク。

## 背景 (#1189 着手前の調査)

- vibe は今 `Module::fn(recv, args...)` を基本形とし、連鎖は `recv |> Module::fn(args...)`
  という pipe で書く設計 (ADR-0020 §3)。
- ただし `docs/method-bearing-traits-plan.md` の 2026-07-04 追記にある通り、
  **`recv.method(args)` の dot 呼び出しは既に部分着地している** — `desugar_trait_dict.vibe`
  が EDot の receiver 型を推論できて `Tn::method` がトップレベル関数として存在すれば
  `Tn::method(recv, args)` に書き換える。つまり #1189 は「UFCS を入れるか」ではなく
  「既にある dot 記法をどこまで積極的に採用・推奨するか」という問題に近い。
- 明示形 (`Module::fn`) と pipe 形 (`recv |> Module::fn(args)`) はどちらも **呼び出し箇所に
  型名が書かれる** という共通点がある。dot 形 (`recv.fn(args)`) だけが型名を消す。
  この非対称性が可読性にどう効くかが本評価の主眼。

## 検証する3つの表記

- **A: explicit** — `Module::fn(recv, args...)`。連鎖時はネストする。
- **B: dot** — `recv.fn(args...)`。連鎖時は `.` で繋がる (仮想 UFCS 前提、一部は #641 で実在)。
- **C: pipe** — `recv |> Module::fn(args...)`。連鎖時は `|>` で縦に並ぶ (現行 vibe 標準)。

## 構成

```
eval/call-style/
  README.md                     # 本ファイル
  scenarios/
    01_overloaded_name/         # 同名メソッドを持つ2型 + 型注釈を伏せた抜粋 → 型/破壊性の復元
    02_arg_order/                # 同じ型の引数が2つ並ぶ場合の順序復元 (表記に依らないはずの対照実験)
    03_chain_readability/        # 4段パイプラインのトレース容易さ・自己申告リーダビリティ
      a_explicit.md / b_dot.md / c_pipe.md   # reader agent に見せる抜粋 + 設問 (表記だけ差し替え)
      ANSWER_KEY.md                          # 正解 + 出題意図 (reader agent には絶対に見せない)
  scores/<date>-r<N>.json        # ラウンドごとの正答率/自己申告スコア集計
  findings/<date>-r<N>.md        # ラウンドの所見 (#1189 へのフィードバック)
```

## ラウンドの回し方

1. 各 `scenarios/*/{a,b,c}_*.md` を個別の reader agent (subagent) に渡す。
   - reader agent は **他の条件ファイルも ANSWER_KEY.md も見ない** (blind)。
   - reader agent には「vibe という初めて見る言語の抜粋である」ことだけ伝え、
     この評価が呼び出し表記を比較する実験であることは伝えない (表記への
     メタ意識がバイアスになるため)。
   - 使うモデルは意図的に軽量モデル (haiku 等) を使う — 「AI がドキュメントを
     読まずにコードだけから意図を汲む」状況を、より弱い推論力で再現するため
     (#1189 の元動機「AI にとっては型が自明な方が読みやすいのでは」を強い
     モデルで検証すると天井効果で差が出ない可能性がある)。
2. 各 reader agent の回答を `ANSWER_KEY.md` と突き合わせて採点する
   (01/02 は正誤、03 は自己申告のトレース可否 + 定性所見)。
3. `scores/<date>-r<N>.json` に集計、`findings/<date>-r<N>.md` に所見を書く。
   major finding は #1189 にコメントするか、必要なら分割 issue にする。
4. **scenarios はラウンド間で安定させる** (追加は可、既存の改変は不可 — 他の
   eval ループと同じ比較可能性のルール)。

## スコア記録形式

`scores/<date>-r<N>.json`:

```json
{
  "round": 1,
  "date": "2026-07-28",
  "model": "claude-haiku-4-5",
  "scenarios": {
    "01_overloaded_name": {"explicit": "correct", "dot": "incorrect_or_hedged", "pipe": "correct"},
    "02_arg_order":        {"explicit": "guessed", "dot": "guessed", "pipe": "guessed"},
    "03_chain_readability": {"explicit": "traced_backwards", "dot": "traced_forwards", "pipe": "traced_forwards"}
  },
  "notes": "1行サマリ"
}
```

## 注意 (このハーネスの限界)

- N=1 (シナリオあたり1回) の少数サンプルなので、統計的な結論ではなく
  **仮説を反証/補強する定性的シグナル**として扱う。傾向が出たら
  シナリオを増やす/複数モデルで回すのが次の一手。
- dot 記法 (B) は現行コンパイラで全パターンが通るとは限らない (#641 は
  「トップレベル関数として存在する場合」限定、ビルトイン全般が対象か未確認)。
  このハーネスは可読性のみを見る純粋な読解実験であり、実装可否の検証では
  ない — 実装可否は別途 `vibe diagnostics` で probe する。
