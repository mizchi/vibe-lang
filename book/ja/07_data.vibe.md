# 07 — 構造体・列挙・match

前: [ミューテーション・region・エスケープ](06_mutation.vibe.md)

English version: [07_data.vibe.md](../en/07_data.vibe.md)

vibe のデータは2つの形のどちらかで、この区別は言語全体を貫いています:

- いくつかのものを**すべて**持つ値 — 点は `x` **と** `y` を持つ — は
  **構造体**;
- いくつかのうち**どれか1つ**である値 — 図形は円 **または** 長方形 — は
  **列挙**。

どちらを分解するのも `match` で、場合を尽くしたかはコンパイラが検査します。

## 軽い形: タプル・配列・レコード

名前付きの形の前に、軽いものを3つ。タプルは決まった個数の値を位置で束ね、
配列は同じ型を多数持ち、レコードは名前を付けなかった構造体です:

```vibe run
fn main with Console {
  let t = (1, "two", true)
  println("t.0 = \{t.0}")
  let a = [
    1,
    2,
    3
  ]
  println("a[0] = \{a[0]}")
  println("Array::length(a) = \{Array::length(a)}")
  let r = record {
    name: "vibe",
    ver: 1
  }
  println("r.name = \{r.name}, r.ver = \{r.ver}")
  let record {
    name: n,
    ver: v
  } = r
  println("n = \{n}, v = \{v}")
}
```

```output
t.0 = 1
a[0] = 1
Array::length(a) = 3
r.name = vibe, r.ver = 1
n = vibe, v = 1
```

最後の2行が分解です。複数のフィールドをローカル名で取り出すもので、
大半を使うときに `r.` を繰り返すより読みやすくなります。

## 構造体

`struct` は形に名前を付けます。`derive` は、その形について自明な演算を
コンパイラに書かせる指示です:

```vibe run
struct Point {
  x: Int; y: Int
} derive (Eq, Ord, Show)

fn main with Console {
  let p = Point::{
    x: 1, y: 2
  }
  println("p.x = \{p.x}")
  println("compare(p, {x:1,y:3}) = \{Point::compare(p, Point::{ x: 1, y: 3 })}")
  println("to_string(p) = \{Point::to_string(p)}")
}
```

```output
p.x = 1
compare(p, {x:1,y:3}) = -1
to_string(p) = Point { x: 1, y: 2 }
```

`Eq` は `==` を、`Ord` は `compare`（-1 / 0 / 1 を返す）を、`Show` は
`to_string` とそれによる補間を与えます。手で書くのは、導出された意味が
欲しいものと違うときだけです。
[ジェネリクス・trait・derive](15_generics.vibe.md)で先へ進みます。

## 列挙

`enum` は選択肢を並べ、それぞれが自分のデータを持ちます。`match` は
どれなのかで分岐します:

```vibe run
enum Shape {
  Circle(Int);
  Rect(Int, Int)
}

fn area(s: Shape) -> Int {
  match s {
    Circle(r) => 3 * r * r,
    Rect(w, h) => w * h
  }
}

fn main with Console {
  println("area(Circle(2)) = \{area(Circle(2))}")
  println("area(Rect(6, 7)) = \{area(Rect(6, 7))}")
}
```

```output
area(Circle(2)) = 12
area(Rect(6, 7)) = 42
```

この enum に `Triangle` を足すと、その面積を述べるまで `area` は
コンパイルが通らなくなります。これが欲しい性質です — 更新が必要な箇所を
コンパイラが見つけてくれるので、場合を足す作業が捜索ではなく作業になります。

## `match` で書けること

パターンは variant に限りません。リテラルに一致させ、`|` で選択肢を並べ、
`if` で条件を足し、`_` で残りを受けられます:

```vibe run
fn classify(n: Int) -> String {
  match n {
    0 => "zero",
    1|2 => "small",
    x if x < 0 => "negative",
    _ => "big"
  }
}

fn main with Console {
  println("classify(0) = \{classify(0)}")
  println("classify(2) = \{classify(2)}")
  println("classify(-5) = \{classify(-5)}")
  println("classify(99) = \{classify(99)}")
}
```

```output
classify(0) = zero
classify(2) = small
classify(-5) = negative
classify(99) = big
```

腕は上から順に試されるので、`x if x < 0` に来るのは `0` / `1` / `2` の
どれでもなかった値だけです。

## 形で束縛する

失敗しえないパターンは `match` なしで直接束縛できます — 関数の中でも、
ファイルのトップレベルでも。右辺は一度だけ評価され、各名前はそこからの
射影です:

```vibe run
struct Version {
  major: Int; minor: Int
}

let (left, right) = (20, 22)

let record {
  name
} = record {
  name: "vibe"
}

let Version::{
  major, minor
} = Version::{
  major: 0, minor: 3
}

fn main with Console {
  println("sum = \{left + right}, \{name} \{major}.\{minor}")
}
```

```output
sum = 42, vibe 0.3
```

**失敗しうる**パターン — enum の variant やリテラル — には `match` か、
あるいは `is` 式が要ります。`is` はパターンを検査し、続く分岐でその名前を
束縛します:

```vibe run
fn main with Console {
  let (a, b) = (1, 2)
  println("a + b = \{a + b}")
  let opt = Some(41)
  if opt is Some(w) {
    println("w = \{w}")
  }
  println("opt is Some(_) = \{opt is Some(_)}")
}
```

```output
a + b = 3
w = 41
opt is Some(_) = true
```

`opt is Some(_)` は単独では単なる `Bool` で、たいていはそれで十分です。

次: [Option とレールウェイ](08_option.vibe.md)。
