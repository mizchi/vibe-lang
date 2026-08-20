# 14 — 落とし穴 (実測)

English version: [14_pitfalls.vibe.md](../en/14_pitfalls.vibe.md) (canonical)

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
(`allows` の項目と `perform` の両方から `?` を落とす) を名指しする。

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

## `==` はまだ完成していない

構造的な `==` は着地の途中 (ADR-0097)。スカラー、タプル、多くの struct は
値で比較される。残る参照等価は、消去された型変数 (`[T: Eq]`)、一部の
関数戻り値経路、空リテラル束縛、要素型がスカラーでない名前経由の配列。
迷ったら意図した比較を自分で書くこと。[等価性](18_equality.vibe.md) を参照。

## `fn` はキーワード

`let fn = 1` は parse error。`r#fn` という逃げ道は無い。束縛の名前を
変えること。

## `for` は常に集めるわけではない

`let xs = for x in arr { x * 2 }` は `Array` なら通る。同じ位置に pull
イテレータを置くと位置付きのエラーになる。`ArrayBuilder` で溜めること。

## Double の補間

`Double` に対する `"\{d}"` が信頼できるのは、その値が float 由来だと
checker が見えているときだけ。注釈のないヘルパの結果は整数のビット
パターンとして表示されうる。引数に注釈を付けるか `d * 1.0` と書くこと。

次章: [付録](../en/99_appendix.md)。
