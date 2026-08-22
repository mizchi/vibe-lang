# 20 — 落とし穴 (実測)

前: [wasm をターゲットにする](19_wasm.vibe.md)

English version: [20_pitfalls.vibe.md](../en/20_pitfalls.vibe.md) (canonical)

ここに挙げるのは、人の午後を 1 つ潰す規則である。どれも現行のコンパイラで
実測した。全一覧は [docs/cheatsheet.md](../../docs/cheatsheet.md) にある。
この章は最初に噛みつくものだけ。

## `handle` の適格性は型システムではない

`handle` が、それが覆う `perform` をすべて見られない場合、プログラムは
型検査を通ってもコンパイルに失敗しうる。body に許されるのは、直接
perform するか、**名前付きのトップレベル `fn`** を呼ぶか、effect row を
持つクロージャ**リテラル**を呼ぶか。local 束縛を経由した呼び出しは
perform を隠してしまう。

```vibe skip
// skip: eligibility rejection — the point is the diagnostic, not a run
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

`String` は byte string。`s[i]` は `Int` の文字コード。`'A' == 65`。
1 文字の String が欲しければ `String::from_char_code(s[i])` かスライス。

## トップレベルは宣言だけ

トップレベルの裸の式は拒否される (ADR-0069)。`fn main` か `test` ブロックに
入れること。

```vibe skip
// skip: ADR-0069 — a file is a list of declarations
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
その解決策。

知っておく価値のある境界は `Eq` の witness を持たない generic な `T` で、
こちらは不意打ちではなくコンパイルエラーになる —
`no impl `Eq` for `Array[Int]`。[等価性](16_equality.vibe.md) を参照。

## `fn` はキーワード

`let fn = 1` は parse error。`r#fn` という逃げ道は無い。束縛の名前を
変えること。

## `for` は常に集めるわけではない

`let xs = for x in arr { x * 2 }` は `Array` なら通る。同じ位置に pull
イテレータを置くと位置付きのエラーになる。`ArrayBuilder` で溜めること。

次: [付録](../en/99_appendix.md)。
