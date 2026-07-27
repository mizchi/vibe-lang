# 03 — データとパターンマッチ

前章: [02 制御フロー](02_control_flow.vibe.md)

## tuple / array / record

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let t = (1, "two", true)
  stdout_write("t.0 = \{t.0}\n")

  let a = [1, 2, 3]
  stdout_write("a[0] = \{a[0]}\n")
  stdout_write("Array::length(a) = \{Array::length(a)}\n")

  // 無名 record は分配束縛で受けるのが確実
  let record { name: n, ver: v } = record { name: "vibe", ver: 1 }
  stdout_write("n = \{n}, v = \{v}\n")
}
```

```output
t.0 = 1
a[0] = 1
Array::length(a) = 3
n = vibe, v = 1
```

record のドットアクセス (`r.name`) は現状「どこかの struct が同名 field を
宣言しているとき」しか解決しない。ad-hoc な record は分配束縛を使う。

## struct と derive

```vibe run
import @vibe/prelude { stdout_write }

struct Point { x: Int; y: Int } derive(Eq, Ord, Show)

fn main with { Stdout } {
  let p = Point::{ x: 1, y: 2 }
  stdout_write("p.x = \{p.x}\n")
  stdout_write("compare(p, {x:1,y:3}) = \{Point::compare(p, Point::{ x: 1, y: 3 })}\n")  // derive(Ord): -1 / 0 / 1
  stdout_write("to_string(p) = \{Point::to_string(p)}\n")                                 // derive(Show)
}
```

```output
p.x = 1
compare(p, {x:1,y:3}) = -1
to_string(p) = Point { x: 1, y: 2 }
```

## enum と match

```vibe run
import @vibe/prelude { stdout_write }

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

fn main with { Stdout } {
  stdout_write("area(Circle(2)) = \{area(Circle(2))}\n")
  stdout_write("area(Rect(6, 7)) = \{area(Rect(6, 7))}\n")
}
```

```output
area(Circle(2)) = 12
area(Rect(6, 7)) = 42
```

## match の道具箱: ガード / or-pattern / リテラル

```vibe run
import @vibe/prelude { stdout_write }

fn classify(n: Int) -> String {
  match n {
    0 => "zero",
    1 | 2 => "small",
    x if x < 0 => "negative",
    _ => "big"
  }
}

fn main with { Stdout } {
  stdout_write("classify(0) = \{classify(0)}\n")
  stdout_write("classify(2) = \{classify(2)}\n")
  stdout_write("classify(-5) = \{classify(-5)}\n")
  stdout_write("classify(99) = \{classify(99)}\n")
}
```

```output
classify(0) = zero
classify(2) = small
classify(-5) = negative
classify(99) = big
```

## 分配束縛と is 式

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let (a, b) = (1, 2)
  stdout_write("a + b = \{a + b}\n")

  let opt = Some(41)
  if opt is Some(w) {
    stdout_write("w = \{w}\n")               // w が束縛される
  }
  stdout_write("opt is Some(_) = \{opt is Some(_)}\n")   // -> Bool
}
```

```output
a + b = 3
w = 41
opt is Some(_) = true
```

## 蓄積は ArrayBuilder

`Array::push` を生 Array に使うのはアンチパターン (backend 依存)。

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let arr = {
    let bld = ArrayBuilder::new()
    ArrayBuilder::push(bld, 1)
    ArrayBuilder::push(bld, 2)
    ArrayBuilder::freeze(bld)   // -> Array[Int]
  }
  stdout_write("length = \{Array::length(arr)}\n")
  stdout_write("arr[1] = \{Array::get(arr, 1)}\n")
}
```

```output
length = 2
arr[1] = 2
```

次章: [04 Option と railway](04_option_result.vibe.md)
