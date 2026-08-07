# enum constructor の `E::` 必須化 — 詳細設計 (#1455 / ADR-0096)

#1455 は決定(`E::` を必須にする)と現状測定だけを記録し、詳細設計を「後日設計」と
して先送りしていた。主論点だった **prelude 例外の有無**が「例外は必須とする」で
決着したので、ここに設計をまとめる。

#1455 の測定 (2026-08-05, `lib/**/*.vibe`) — ctor 種類 501、bare 使用 27,261 箇所、
qualified 使用 0 箇所。上位は `EIdent` / `CtInt` / `ECall` / `EInt` / `CToken` で、
**移行対象の大半はコンパイラ自身**。負担はほぼ自分たちに閉じている。

## 決定

1. **enum constructor は構築・パターンの両方で `E::T` の修飾を必須とする。**
2. **prelude 例外を設ける** — 免除された constructor は bare のまま合法。

## 免除集合 — 「prelude」は一様ではない

設計上いちばん重要な発見。免除の性質が `Option` と `Result` で違う。

### `Option` の `Some` / `None` — 免除は実装上ほぼ強制

`Some` / `None` は **enum 宣言を持たない**。`CtOption` に直結した builtin として
checker にハードコードされている (`checker.vibe` の `name == "Some"` 等)。実測:

<!-- skip 理由: 拒否される綴り (`Option::Some`) を意図的に見せており、かつ同名
     `fn f` を4つ並べた対比表なので、doctest に載せると必ず落ちる。 -->

```vibe skip
fn f() -> Option[Int] { Some(1) }          // ok
fn f() -> Option[Int] { Option::Some(1) }  // error: unknown name: Option::Some
fn f() -> Option[Int] { None }             // ok
fn f() -> Option[Int] { Option::None }     // error: unknown name: Option::None
```

**`Option::Some` は現状そもそも書けない。** 修飾を強制するなら、その前に `Option`
を本物の enum にする(または qualifier 側を特別扱いする)必要があり、これは #1455
本体より大きい変更になる。**したがって `Option` の免除は選択ではなく前提**。

### `Result` の `Ok` / `Err` — 免除は本当の選択

`Result[T, E]` は `@vibe/wit_runtime` の**通常の enum** で、通常 enum は既に
`E::T` 修飾が書ける(`Wrap::Only(7)` が動くことは #1512 の回帰テストで確認済み)。
つまり `Result::Ok` は綴れる。ここを免除するかは純粋に人間工学の判断。

**本設計では `Result` も免除する。** 理由: (a) `Option` が免除である以上、
`Some(v)` は bare で `Result::Ok(v)` は修飾必須、という非対称は覚える規則を
増やすだけで安全性を足さない。(b) #1455 の動機は「constructor がプログラム全体で
グローバルなので黙って別の型に付け替わる」だが、`Ok`/`Err` は衝突したときに
**型エラーとして顕在化する**(#1345 の `Attempt` 実測がまさにそれ)。黙って壊れる
ケースではない。

### 免除集合の定義(実装が参照する唯一の定義)

```
PRELUDE_EXEMPT = { Some, None, Ok, Err }
```

**名前ベースの固定リストにする。** パッケージ境界(「@vibe/prelude 由来なら免除」)
にしない理由: `Some`/`None` はそもそもどのパッケージにも属さない builtin で、
`Ok`/`Err` は `@vibe/wit_runtime` にあり、「prelude」という単一の出所が実在しない。
出所で定義すると実装が二経路になり、境界がぶれる。

**利用者がこの4つと同名の variant を自分の enum に宣言した場合は修飾必須のまま**
(免除は上記の4つの *定義元* に対してであって、綴りに対してではない)。この判定には
「その bare 名がどの enum に解決されたか」が必要で、checker はそれを持っている。

## 移行 — #1429 で機能した2段構え

#1429(effect row の綴り移行)と同じ形をとる。

| Phase | 内容 | 受理する綴り |
|---|---|---|
| 0 | (完了) 修飾形が parser/checker/codegen を通る | bare / qualified 両方 |
| 1 | **一括変換** — `lib/**` の bare を `E::` へ | 両方 |
| 2 | **bare を named error で拒否**(免除集合を除く) | qualified のみ |

Phase 0 は既に成立している — #1455 が「新しい構文は要らない」と書いたとおりで、
#1502/#1510(エイリアス修飾)と #1512(型仮引数の shadow)はその前提工事だった。

### Phase 1 の変換器をどこに置くか

**formatter は使わない。** CST-token formatter は型情報を持たないので、bare
`Ok(7)` を見ても `Result::Ok` なのか利用者定義 enum なのか決められない。
`EIdent`/`ECall` の head がどの enum の constructor かは **checker だけが知って
いる**。したがって変換は checker の解決結果を使う一回限りのツール
(`vibe migrate --qualify-ctors` 相当)として書き、結果を commit する。

27,261 箇所を一括で書き換えるので、**変換前後で stage2 が byte-identical**である
ことを受け入れ条件にする(修飾は綴りの変更であって意味論の変更ではないため、
codegen 出力は変わらないはず)。ここが崩れたら変換器のバグ。

### Phase 2 と bootstrap seed の関係

**seed が qualified 形を理解できることを先に tag する**(docs/bootstrap.md の
運用どおり)。Phase 0 が既に成立しているので現行 seed は両方読めるはずだが、
Phase 2 で bare を**拒否**するようにした compiler source を、bare を含む古い
seed でビルドできるかは別問題。順序は Phase 1(変換・両方受理のまま)→ bootstrap
bump → Phase 2(拒否)。

## 「import も必須」の側

#1455 のもう半分「constructor を使う側はその enum を import していることも必須」
は、**#1521 が前提**。現状 import は名前の実在を検査しておらず(存在しない名前の
import が checker を素通りする)、「import していること」を要求する土台が無い。
#1521 を先に閉じる。

## エラーメッセージ

bare 拒否は行動可能な文面にする(CLAUDE.md の「エラー文が内部用語で行動可能で
ない」を踏まないこと):

```
error: bare constructor `Only` is not allowed; write `Wrap::Only`
  --> foo.vibe:12:15
  = `Only` is a constructor of enum `Wrap` (declared at bar.vibe:3:6)
  = Some / None / Ok / Err are exempt and stay bare
```

解決先の enum 名を必ず出す — 修飾必須にする動機が「どの enum の constructor か
曖昧」である以上、エラーがその答えを持っていないと意味がない。

## 未決 / 次に測ること

- **単一 constructor enum の例外**は設けない(規則を増やす割に得るものが無い)。
  ただし実際に書いてみて煩雑なら再考の余地あり
- Phase 1 の変換器が `SQualifiedPatternRefs`(#1455 step 3 で入れた parser 側の
  side channel)とどう噛み合うか未確認
- 免除4名と同名の利用者定義 variant が `lib/**` に実在するか未計測。実在するなら
  Phase 2 のエラーが大量に出るので、Phase 1 の前に数える
