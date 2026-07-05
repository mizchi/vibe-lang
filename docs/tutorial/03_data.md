# 03 — データとパターンマッチ

実行: `vibe test docs/tutorial/03_data_test.vibe`

## tuple / array / record

```vibe
let t = (1, "two", true)
t.0                          // 1

let a = [1, 2, 3]
a[0]                         // 1
Array::length(a)             // 3

// 無名 record は分配束縛で受けるのが確実
let record { name: n, ver: v } = record { name: "vibe", ver: 1 }
```

record のドットアクセス (`r.name`) は現状「どこかの struct が同名 field を
宣言しているとき」しか解決しない。ad-hoc な record は分配束縛を使う。

## struct と derive

```vibe
struct Point { x: Int; y: Int } derive(Eq, Ord, Show)

let p = Point::{ x: 1, y: 2 }
p.x                                        // field アクセス
Point::compare(p, Point::{ x: 1, y: 3 })  // derive(Ord): -1 / 0 / 1
Point::to_string(p)                        // derive(Show): "Point { x: 1, y: 2 }"
```

## enum と match

```vibe
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
```

## match の道具箱: ガード / or-pattern / リテラル

```vibe
match n {
  0 => "zero",
  1 | 2 => "small",
  x if x < 0 => "negative",
  _ => "big"
}
```

## 分配束縛と is 式

```vibe
let (a, b) = (1, 2)

let opt = Some(41)
if opt is Some(w) { /* w が束縛される */ }
opt is Some(_)               // -> Bool
```

## 蓄積は ArrayBuilder

`Array::push` を生 Array に使うのはアンチパターン (backend 依存)。

```vibe
let arr = {
  let bld = ArrayBuilder::new()
  ArrayBuilder::push(bld, 1)
  ArrayBuilder::push(bld, 2)
  ArrayBuilder::freeze(bld)   // -> Array[Int]
}
```

次章: [04 Option と railway](04_option_result.md)
