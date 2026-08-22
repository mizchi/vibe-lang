# 20 — 落とし穴 (実測)

前: [wasm をターゲットにする](19_wasm.vibe.md)

English version: [20_pitfalls.vibe.md](../en/20_pitfalls.vibe.md) (canonical)

ここに挙げるのは、人の午後を 1 つ潰す規則である。どれも現行のコンパイラで
実測した。全一覧は [docs/cheatsheet.md](../../docs/cheatsheet.md) にある。
この章は最初に噛みつくものだけ。

## `handle` の適格性は型システムではない

`handle` が、それが覆う `perform` をすべて見られない場合、プログラムは
型検査を通ってもコンパイルに失敗しうる。規則は**effect row** についての
ものであって、callee がどこに書かれたかではない。local 束縛や引数を
経由した呼び出しも、その型が row を持っていれば通る。performする
トップレベル `fn` を別名で束縛しただけのものも通る。

失敗するのは、**handled body の外で宣言された row を持たないクロージャ**。
その呼び出しが何を perform するかを handle に伝えるものが無い。同じ
クロージャを body の**内側**で宣言すれば通るし、row を付けても通る。
実測した全一覧は [docs/cheatsheet.md](../../docs/cheatsheet.md) にある。

```vibe skip
// skip: 適格性による拒否 — 見せたいのは診断であって実行ではない
effect Ask {
  Get() -> Int
}

fn main with Exception {
  let bump = (x: Int) -> Int {
    x + 1
  }
  let n = handle {
    bump(perform Ask::Get())
  } with Ask {
    Get() => resume(0)
  }
  ()
}
```

```
handle of effect 'Ask' cannot be compiled here: this handle cannot see what
one call in its body performs (here: the call to 'bump'). Make that call
visible -- declare 'bump' as a top-level `fn`, give the binding or parameter
it arrives through an effect row (`with Ask`), or move its `let` inside the
handled body. Moving the `handle` into the function that performs works too.
(ADR-0076 evidence-passing migration.)
```

`bump` に effect row が**無い**ことに注意。リテラルに `with Ask` を付けると、
それはメッセージが挙げる4つの直し方のひとつなのでコンパイルが通る — そこが
要点で、束縛に付いた row が perform を見えるようにしている。`bump` を
トップレベルの `fn` に持ち上げるのも同じく有効。

## `Int` の幅はタグビットに従う

`Int` は **63-bit** (タグビット 1 本、ADR-0105)。リテラルの最大は
`4611686018427387903`。`max + 1` はどのバックエンドでも
`-4611686018427387904` に wrap する。まだ `2^61-1` / 62-bit と書いてある
文章は古い。

## `perform?` は checker が拒否する

`perform? Fs::read_file(p)` は `allows Fs::read_file?` の下で
`Attempt[T, String]` と型付けされるが、codegen が lowering できないため
checker が拒否する (#2145): *"`perform?` is not lowered yet"* と、直し方
(`allows` の項目から `?` を落とし、`Fs::read_file(..)` を普通に呼ぶ) を
名指しする。`allows` に載るのは capability だけで、capability は perform
しない。

`vibe check` も同じことを言うので、ビルド前に分かる。#2145 が着地する前は
型検査を通ったあとで ICE になっていた。

## 文字列補間にはレンダラが要る

`\{x}` で補間するユーザー struct には `derive(Show)` か
`fn T::to_string(v) -> String` が要る。スカラー・`Option`・タプル・配列は
既にレンダリングされる。Show が無いとかつてはポインタが表示されたが、
今はエラー (#1445)。

## `s[i]` は String ではなくバイト

`String` は byte string。`s[i]` はそのオフセットのバイトで、`Int`。
`'A' == 65`。1 バイトの String が欲しければ `String::from_char_code(s[i])`
— これはバイト書き込みで、別名 `String::from_byte` (#2203) — かスライス。
そのバイトが文字そのものなのは ASCII のときだけ。

## トップレベルは宣言だけ

トップレベルの裸の式は拒否される (ADR-0069)。`fn main` か `test` ブロックに
入れること。

```vibe skip
// skip: ADR-0069 — ファイルは宣言の並びである
1 + 2
```

```
top-level expressions are not allowed; move it into fn main (ADR-0069)
```

## `test` / `bench` は文字列を取るか何も取らないか

`test { }` と `test "name" { }` は通る。`test foo { }` (裸の識別子) は
通らない。

## `Error` と `Exception`

effect は `Exception`。effect の綴りとしての `Error` は deprecated
(ADR-0085)。古い row では `Error` が**操作の修飾子**として今も見えるが、
新しく増やさないこと。

## 配列の `==`

`==` は値で比較する。要素がスカラーでない配列も、関数の戻り値として来た
配列も、空リテラルも — 注釈の有無によらず — そうなる。注釈の無い
`let xs = []` は、それを埋める `Array::push` から要素型を受け取る (#2157)。
ただし **push する値が自分で型を語る場合に限る** — リテラル、リテラルだけ
からなる配列・tuple・struct、両分岐が一致する `if` がそれにあたる。

名前や呼び出しの結果を push した束縛には要素型が付かず、両側とも非空になった
状態で比較すると、答えを返さず実行時に失敗する。`let xs: Array[Int] = []` が
その解決策。型引数を取る struct が「自分で型を語る」と見なされるのは、
`==` が内容で比較する型引数のときだけ — `Box[Int]` / `Box[Bool]` /
`Box[Unit]` / `Box[String]` は解決し、`Box[Double]` / `Box[Bytes]` と
配列や struct の型引数は解決しない。

知っておく価値のある境界は `Eq` の witness を持たない generic な `T` で、
こちらは不意打ちではなくコンパイルエラーになる —
`no impl `Eq` for `Array[Int]`。[等価性](16_equality.vibe.md) を参照。

## 演算子で始まる行は前の行の続き

次の行が演算子で始まるとき、改行は式を終わらせない。ブロックの最終値の
つもりで書いた負のリテラルが、上の行に貼り付く:

```vibe skip
// skip: 出る診断を見せるための例 — `-1` は `println(...) - 1` とパースされる
fn main with Console {
  let v = {
    println("failing")
    -1
  }
  println("\{v}")
}
```

```
line 3:5: type mismatch in '-': operands must be Int or Double
```

`(-1)` と書くか、先に束縛する。match 腕の直接の本体としての負リテラル
(`None => -1`) は問題ない。診断はまだ行継続を原因として名指ししない
(#2206)。

## `fn` はキーワード

`let fn = 1` は parse error。`r#fn` という逃げ道は無い。束縛の名前を
変えること。

## `for` は常に集めるわけではない

`let xs = for x in arr { x * 2 }` は `Array` なら通る。同じ位置に pull
イテレータを置くと位置付きのエラーになる。`ArrayBuilder` で溜めること。

次: [付録](../en/99_appendix.md)。
