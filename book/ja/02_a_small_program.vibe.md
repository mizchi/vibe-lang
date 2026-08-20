# 02 — 小さなプログラム

前: [インストールと Hello, vibe](01_getting_started.vibe.md)

English version: [02_a_small_program.vibe.md](../en/02_a_small_program.vibe.md)

hello world で分かるのはツールチェインが動くことだけで、その言語を学ぶ
価値があるかどうかは分かりません。そこで構文ツアーに入る前に、何かをする
プログラムを1本置きます。式の木を評価して、印字して、ゼロ除算にも対処する
電卓です。

40行ほどで、まだ何も教わっていない構文ばかりです。細部は後の章が埋めるので、
まずは全体として読んでください。

```vibe run
enum Expr {
  Num(Int);
  Add(Expr, Expr);
  Mul(Expr, Expr);
  Div(Expr, Expr)
}

fn eval(e: Expr) -> Int with Exception {
  match e {
    Num(n) => n,
    Add(a, b) => eval(a) + eval(b),
    Mul(a, b) => eval(a) * eval(b),
    Div(a, b) => {
      let d = eval(b)
      if d == 0 {
        throw("divide by zero")
      } else {
        eval(a) / d
      }
    }
  }
}

fn show(e: Expr) -> String {
  match e {
    Num(n) => Int::to_string(n),
    Add(a, b) => "(\{show(a)} + \{show(b)})",
    Mul(a, b) => "(\{show(a)} * \{show(b)})",
    Div(a, b) => "(\{show(a)} / \{show(b)})"
  }
}

fn report(e: Expr) -> String {
  handle {
    "\{show(e)} = \{eval(e)}"
  } with Exception {
    Throw(message) => "\{show(e)} failed: \{message}"
  }
}

fn main with Console {
  println(report(Add(Num(2), Mul(Num(4), Num(10)))))
  println(report(Div(Num(84), Num(2))))
  println(report(Div(Num(1), Add(Num(3), Num(-3)))))
}
```

```output
(2 + (4 * 10)) = 42
(84 / 2) = 42
(1 / (3 + -3)) failed: divide by zero
```

## いま使ったもの

**木を一度だけ記述する。** `enum Expr` は式が取りうる4つの形を並べたもので、
`Div(Expr, Expr)` は定義の途中で `Expr` 自身を参照しています。`match` はその
木を分解します。5つ目の形を足して処理を忘れれば、実行時にどれかの枝が選ばれる
のではなく、どの関数が不完全になったかをコンパイラが指摘します。
→ [構造体・列挙・match](07_data.vibe.md)

**失敗しうることを明示する関数。** `eval` は `-> Int with Exception` と
書かれています。この `with Exception` は注釈ではありません。呼び出す側は
その可能性を持ち回るか、その場で処理するかのどちらかで、どちらなのかは
コンパイラが判定します。`report` は処理する側なので、戻り値はただの
`String` です — 失敗はそこで止まります。
→ [エフェクト](13_effects.vibe.md)

**`main` は自分に許されたことを宣言する。** `fn main with Console` は
端末への書き込み許可であり、このプログラムに許されているのは*それだけ*です。
ファイルを読むこともソケットを開くこともできません。要求していないからです。
→ [ケーパビリティ](14_capabilities.vibe.md)

立ち止まる価値があるのは最後の点です。多くの言語では「この関数は印字する」
「この関数は失敗しうる」は、本体を読んで気づくか、本番で驚かされて知る事実
です。vibe ではそれが署名にあり、コンパイラが検査し、そして合成されます —
`eval` と `println` の両方を呼ぶ関数は、両方を必要とします。

## 自分のものにする

小さいまま最も学べる変更を2つ:

1. **`Sub(Expr, Expr)` を足す。** variant を足して、他には何も触らずに
   コンパイルしてください。穴の空いた `match` すべてをエラーが指します。
2. **除算をゼロ方向への切り捨てとして明示する**、あるいは負の除数でも
   失敗させる。変更が `eval` だけで済み、`report` には及ばないことに注目
   してください — 失敗の経路は既に宣言済みだからです。

次: [値と関数](03_values_functions.vibe.md)
