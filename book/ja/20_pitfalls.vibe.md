# 20 — 落とし穴 (実測)

前: [wasm をターゲットにする](19_wasm.vibe.md)

English version: [20_pitfalls.vibe.md](../en/20_pitfalls.vibe.md) (canonical)

ここに挙げるのは、人の午後を 1 つ潰す規則である。どれも現行のコンパイラで
実測した。全一覧は [docs/user/reference/cheatsheet.md](../../docs/user/reference/cheatsheet.md) にある。
この章は最初に噛みつくものだけ。

## `handle` の適格性は型システムではない

`handle` が、それが覆う `perform` をすべて見られない場合、プログラムは
型検査を通ってもコンパイルに失敗しうる。呼び出しが「見える」条件は 2 つ。
callee の型が **effect row を持っている**か、handle がもともと見通せる
callee であるか — トップレベル `fn`、それを別名で束縛したもの、あるいは
handled body の**内側**で宣言されたクロージャ。

したがって local 束縛や引数を経由した呼び出しも、その型が row を持って
いれば通る。local 束縛であること自体が問題なのではない。失敗するのは
**handled body の外で宣言された row を持たないクロージャ**で、その
呼び出しが何を perform するかを handle に伝えるものが無い。row を付けるか、
`let` を body の内側へ移す — 診断はその両方を挙げる。実測した全一覧は
[docs/user/reference/cheatsheet.md](../../docs/user/reference/cheatsheet.md) にある。

```vibe skip
// skip: 適格性による拒否 — 見せたいのは診断であって実行ではない
effect Ask {
  Get() -> Int
}

fn main allows Exception {
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

## 行頭の `-` は被演算子に接しているときだけ前置

次の行が演算子で始まるとき、改行は式を終わらせない。ただし例外が一つある:
行頭の `-` / `!` / `~` は、被演算子との間に空白が無ければ**前置**演算子に
なる (#3041)。だから単独の行の `-1` は新しい式を始め、`- 1` (`-` の後に
空白) は上の行の続きとして引き算になる:

```vibe run
fn main allows Console {
  let a = 10
  let fresh = {
    println("computing")
    -1
  }
  let continued = a
    - 1
  let trailing = a -
    1
  println("\{fresh} \{continued} \{trailing}")
}
```

```output
computing
-1 9 9
```

決め手は `-` の後の空白なので、折り返す引き算は 1 行で `a - 1` と書くか、
次の行頭に `- 1` と書くか、`-` を前の行の末尾に置く。それ以外の行頭の演算子
(`+`, `*`, `|>`, `&&` など) は常に前の行の続きになる。`Unit` を返す文の後に
空白付きの `- 1` を書くと型エラーになり、メッセージは二つの直し方 —
空白を消す、または `(-1)` と書く — を名指しする。

## `fn` はキーワード

`let fn = 1` は parse error。`r#fn` という逃げ道は無い。束縛の名前を
変えること。

## `for` は常に集めるわけではない

`let xs = for x in arr { x * 2 }` は `Array` なら通る。同じ位置に pull
イテレータを置くと位置付きのエラーになる。`ArrayBuilder` で溜めること。

次: [付録](../en/99_appendix.md)。
