# 05 — 型と文字列

前: [制御フロー](04_control_flow.vibe.md)

English version: [05_types_strings.vibe.md](../en/05_types_strings.vibe.md)

ここまで `Int` / `Double` / `Bool` / `String` / `Char` を使ってきました。
この章はそれらが正確には何なのかを述べます。他の言語からの類推で間違える
と、エラーではなく**誤った答え**が返ってくるのがこれらの型だからです。

## `Int` の幅は63ビット

64ではありません。範囲は `-2^62 .. 2^62-1` で、`4611686018427387903` を
超えるリテラルは切り捨てではなく拒否されます。

範囲を出た演算は63ビットの2の補数として**ラップ**します。どのバックエンド
でも同一なので、`max + 1` は `min` です:

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

C 系の言語と違う点が3つあります:

- `>>` は算術シフトで符号拡張します。`>>>` はありません。論理シフトが
  欲しければ後からマスクしてください。
- `~` はありません。`x ^ mask` と書きます。
- 暗黙の昇格はありません。63ビットを超える必要が出たら、`@vibe/core` の
  `BigInt` を意識して使います。

## `Double` と `Float`

小数リテラルは `Double`（64ビット）です。32ビットの `Float` には `f`
接尾辞が要ります: `1.5f`。

実務上の注意を1つ。`Double` の補間が期待どおりの小数を印字するのは、
その値が浮動小数点だと型検査器に見えている場合です — リテラル、浮動小数点
演算、注釈付きの引数はいずれも該当します。印字が大きな整数に見えたら、
値が型を伴わずに補間に届いています。束縛か引数に注釈を付けてください。

## `String` はバイト列

ここが一番驚かれるところです。`s[i]` は `Int` — その位置のバイト — であって
1文字の `String` ではありません。添字も長さもバイト数です。

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

`String::from_char_code` はコードを `String` に戻します。4つのスライス形式
— `s[:]` / `s[:n]` / `s[n:]` / `s[a:b]` — は `Bytes` と `Array[T]` でも
同じように使えます。

添字がバイトなので、スライスは Unicode のコードポイント境界を尊重しません。
ASCII のスライスは安全ですが、任意のテキストを任意の位置で切るのは安全では
ありません。これは意図的な選択です — メモリがバイトである以上、型もバイトだと
言う方が、そうでないふりをするより誠実だからです。

## 補間

`"hello \{x}"` が唯一の補間構文で、波括弧には任意の式が入ります。補間できる
のは、その型の `to_string` をコンパイラが見つけられる場合です。スカラー、
`Option`、タプル、配列は最初から持っており、自分の型は `derive (Show)` で
得られます。

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

`derive (Show)` を外すと `Point` の補間はコンパイルエラーになります。それが
意図した答えです — 代わりにアドレスが印字される方が、誤った答えです。

次: [ミューテーション・region・エスケープ](06_mutation.vibe.md)
