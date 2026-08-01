# 03 — データとパターンマッチ

前章: [02 制御フロー](02_control_flow.vibe.md)

## tuple / array / record

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let t = (1, "two", true)
  stdout_write("t.0 = \{t.0}\n")
  let a = [
    1,
    2,
    3
  ]
  stdout_write("a[0] = \{a[0]}\n")
  stdout_write("Array::length(a) = \{Array::length(a)}\n")
  let r = record {
    name: "vibe",
    ver: 1
  }
  stdout_write("r.name = \{r.name}, r.ver = \{r.ver}\n")
  // 分配束縛も、複数の field を局所名へ取り出すときに使える
  let record {
    name: n,
    ver: v
  } = r
  stdout_write("n = \{n}, v = \{v}\n")
}
```

```output
t.0 = 1
a[0] = 1
Array::length(a) = 3
r.name = vibe, r.ver = 1
n = vibe, v = 1
```

anonymous record も `r.name` のように field を読める。分配束縛は複数 field を
局所名へ取り出す場合の選択肢であり、accessor の回避策ではない。

## struct と derive

```vibe run
import @vibe/prelude {
  stdout_write
}

struct Point {
  x: Int; y: Int
} derive (Eq, Ord, Show)

fn main with { Stdout } {
  let p = Point::{
    x: 1, y: 2
  }
  stdout_write("p.x = \{p.x}\n")
  stdout_write("compare(p, {x:1,y:3}) = \{Point::compare(p, Point::{ x: 1, y: 3 })}\n")
  // derive(Ord): -1 / 0 / 1
  stdout_write("to_string(p) = \{Point::to_string(p)}\n")
  // derive(Show)
}
```

```output
p.x = 1
compare(p, {x:1,y:3}) = -1
to_string(p) = Point { x: 1, y: 2 }
```

## enum と match

```vibe run
import @vibe/prelude {
  stdout_write
}

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
import @vibe/prelude {
  stdout_write
}

fn classify(n: Int) -> String {
  match n {
    0 => "zero",
    1|2 => "small",
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

### トップレベルの irrefutable pattern（目標）

**目標の言語**では、必ず一致する pattern はトップレベルでも束縛できる。
[#1281](https://github.com/mizchi/vibe-lang/issues/1281) で追跡中であり、現在の
コンパイラでは実行しない。RHS は top-level-pure で一度だけ評価される。enum variant・
literal・guard・or-pattern のような refutable pattern は許可しない。

```vibe skip
// target (#1281): tuple / record / struct の irrefutable pattern を許可する。
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

fn main with { Stdout } {
  stdout_write("sum = \{left + right}, \{name} \{major}.\{minor}\n")
}
```

### 現行互換: 関数本体で束縛

現在は同じ束縛を関数本体に置く。次は現行コンパイラで runnable な fallback である。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let (a, b) = (1, 2)
  stdout_write("a + b = \{a + b}\n")
  let opt = Some(41)
  if opt is Some(w) {
    stdout_write("w = \{w}\n")
    // w が束縛される
  }
  stdout_write("opt is Some(_) = \{opt is Some(_)}\n")
  // -> Bool
}
```

```output
a + b = 3
w = 41
opt is Some(_) = true
```

## 蓄積は ArrayBuilder

現行では `Array::push` を生 Array に使わず `ArrayBuilder` を使う（backend 依存の
挙動を解消する API 方針は [#1285](https://github.com/mizchi/vibe-lang/issues/1285) で追跡中）。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let arr = {
    let bld = ArrayBuilder::new()
    ArrayBuilder::push(bld, 1)
    ArrayBuilder::push(bld, 2)
    ArrayBuilder::freeze(bld)
    // -> Array[Int]
  }
  stdout_write("length = \{Array::length(arr)}\n")
  stdout_write("arr[1] = \{Array::get(arr, 1)}\n")
}
```

```output
length = 2
arr[1] = 2
```

次章: [04 Option](04_option.vibe.md)
