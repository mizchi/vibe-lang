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
  Get -> Int
}

fn main with Exception {
  let bump = (x: Int) -> Int with Ask {
    x + 1
  }
  handle {
    bump(perform Ask::Get)
  } with Ask {
    Get => resume(0)
  }
}
```

診断は呼び先 (`bump`) とその `line:col` を名指しする。直し方は `bump` を
トップレベルの `fn` に持ち上げること。

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
名指しする。代数 effect の operation なら同じメッセージが `perform` を残す —
capability builtin は perform しないため。

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

## `test` / `bench` は文字列を取るか何も取らないか

`test { }` と `test "name" { }` は通る。`test foo { }` (裸の識別子) は
通らない。

## `Error` と `Exception`

effect は `Exception`。effect の綴りとしての `Error` は deprecated
(ADR-0085)。古い row では `Error` が**操作の修飾子**として今も見えるが、
新しく増やさないこと。

## 空の配列リテラルには注釈を付ける

`==` は値で比較する。要素がスカラーでない配列も、関数の戻り値として来た
配列も、注釈のある空配列もそうなる。刺さるのは一つだけ: 注釈の無い
`let xs = []` は要素型を持たないので、push したあとに比較すると答えを
返さず**実行時に trap する** (#2157)。`let xs: Array[Int] = []` と書くこと。

もう一方の境界は `Eq` の witness を持たない generic な `T` で、こちらは
不意打ちではなくコンパイルエラーになる — `no impl `Eq` for `Array[Int]`。
[等価性](16_equality.vibe.md) を参照。

## `fn` はキーワード

`let fn = 1` は parse error。`r#fn` という逃げ道は無い。束縛の名前を
変えること。

## `for` は常に集めるわけではない

`let xs = for x in arr { x * 2 }` は `Array` なら通る。同じ位置に pull
イテレータを置くと位置付きのエラーになる。`ArrayBuilder` で溜めること。

## 関数から返った `Double` はゴミを表示する (#2158)

**呼び出し**を経由して届いた `Double` を補間すると、生のビットが整数として
表示されます。コンパイルは通り、それらしい誤った数値が出ます。この章で
一番たちの悪い項目です。

```vibe skip
// skip: 失敗せず誤った数値を表示する -- #2158
fn half(a: Double) -> Double { a / 2.0 }

fn main with Console {
  let bound = half(5.0)
  println("\{bound}")        // 232   -- 誤り
  println("\{half(5.0)}")    // 404   -- 誤り
}
```

`half` には注釈が完全に付いていて、それでも変わりません。レンダラは宣言
された戻り値型ではなく、補間の位置にある**構文**から判断しています。効く
書き方は3つ:

```vibe run
fn half(a: Double) -> Double {
  a / 2.0
}

fn main with Console {
  let annotated: Double = half(5.0)
  println("annotate the binding = \{annotated}")
  println("add arithmetic       = \{half(5.0) + 0.0}")
  println("to_string            = \{Double::to_string(half(5.0))}")
}
```

```output
annotate the binding = 2.5
add arithmetic       = 2.5
to_string            = 2.5
```

**引数**への注釈は効きません。効くのは使う場所の束縛の方です。

次: [付録](../en/99_appendix.md)。
