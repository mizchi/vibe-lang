# 08 — 型と文字列

English version: [08_types_strings.vibe.md](../src/08_types_strings.vibe.md) (canonical)

1 章では `Int` / `Double` / `Bool` / `String` / `Char` を値として見た。
この章はそれらの型が実際に守っている契約 — 他の言語からの類推で書くと
黙って誤った答えが返ってくる箇所 — を扱う。

## `Int` は 63-bit であって「機械の i64」ではない

ADR-0105 (#1877): 出荷している表現はタグビットを **1 本**使うので、正直な幅は
63。範囲は `-2^62 .. 2^62-1`。`4611686018427387903` (`2^62-1`) を超える
リテラルは `IntLiteralOverflow` として拒否される。算術オーバーフローは
**どのバックエンドでも** 63-bit の 2 の補数で wrap する — `max + 1` は `min`。
「62-bit / `2^61-1`」と書いてある古い文章は、コンパイラがもう使っていない
タグ配置を説明している。

```vibe run
fn main with Console {
  let max = 4611686018427387903
  println("max = \{max}")
  println("max + 1 = \{max + 1}")
  println("hex 0xFF = \{0xFF}")
  println("1 << 4 = \{1 << 4}")
  let neg = 0 - 8
  println("(-8) >> 1 = \{neg >> 1}")
}
```

```output
max = 4611686018427387903
max + 1 = -4611686018427387904
hex 0xFF = 255
1 << 4 = 16
(-8) >> 1 = -4
```

`>>` は**算術**シフト (符号拡張あり)。`>>>` は無い。`~` も無いので
`x ^ mask` と書く。もっと大きい整数は暗黙の昇格ではなく `@vibe/core` の
`BigInt` の担当。

## `Float` と `Double`

裸の小数は `Double` (64-bit)。`Float` (32-bit) には `f` サフィックスが要る
(`1.5f`)。`Double` の文字列補間が期待どおりの小数を出すのは、その値が
float 由来だと checker が見えているとき (リテラル、float として追跡された
local、float の算術、注釈された引数) だけ。出力が整数のビットパターンに
見えるなら、注釈のないヘルパの結果を `* 1.0` か `Double` 引数に通すこと。

## `String` は byte string

`s[i]` は 1 文字の `String` ではなく `Int` の文字コード。`'A'` は `65`。
インデックスはバイトオフセット。これが正直な意味論で、メモリがバイトなら
型もバイトである (ADR-0098)。

```vibe run
fn main with Console {
  let s = "hello"
  println("s[0] = \{s[0]}")
  println("from_char_code = \{String::from_char_code(s[0])}")
  println("s[:] = \{s[:]}")
  println("s[:2] = \{s[:2]}")
  println("s[2:] = \{s[2:]}")
  println("s[1:4] = \{s[1:4]}")
  println("length = \{String::length(s)}")
}
```

```output
s[0] = 104
from_char_code = h
s[:] = hello
s[:2] = he
s[2:] = llo
s[1:4] = ell
length = 5
```

4 つのスライス綴り — `s[:]`、`s[:n]`、`s[n:]`、`s[a:b]` — は `Bytes` と
`Array[T]` でも使える。これらは Unicode のコードポイントを歩かない。

## 文字列補間

`"hello \{x}"` が唯一の補間の綴り。値が補間できるのは、checker が
`T::to_string` を見つけられるとき (`derive(Show)`、手書きのメソッド、
組み込みのレンダラ)。スカラー・`Option`・タプル・配列は既にレンダリング
される。Show の無いユーザー struct はかつてポインタを表示していたが、
今はコンパイルエラー。

```vibe run
struct Point {
  x: Int; y: Int
} derive (Show)

fn main with Console {
  let p = Point::{
    x: 3, y: 4
  }
  println("p = \{Point::to_string(p)}")
  println("opt = \{Some(1)}")
  println("pair = \{(2, 3)}")
}
```

```output
p = Point { x: 3, y: 4 }
opt = Some(1)
pair = (2, 3)
```

次章: [コレクション](15_collections.vibe.md)。
