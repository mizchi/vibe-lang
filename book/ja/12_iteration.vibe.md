# 17 — 反復

English version: [12_iteration.vibe.md](../en/12_iteration.vibe.md) (canonical)

vibe は 2 層に分けている (ADR-0099)。

1. **eager な `Array::*`** — `map`、`fold`、`filter`、`for x in xs`。
   結果は即座に配列になる。
2. **pull な `AsyncIter`** — suspend できる `next`。生産側がストリームで
   あって、既に手元にあるコレクションではないときに使う。

prelude に遅延イテレータのコンビネータ連鎖は無い。配列を 1 回走査したい
なら `Array::*` の呼び出しか `for` を書く。pull したいなら `for await`
ではなく pull 型を使う (`for await` は削除された。suspend は effect row に
載る)。

## eager な配列ツール

```vibe run
fn main with Console {
  let xs = [
    1,
    2,
    3,
    4
  ]
  let evens = Array::filter(xs, (n) -> {
    n % 2 == 0
  })
  let sum = Array::fold(xs, 0, _ + _)
  let doubled = for x in xs {
    x * 2
  }
  println("evens length = \{Array::length(evens)}")
  println("sum = \{sum}")
  println("doubled[3] = \{Array::get(doubled, 3)}")
}
```

```output
evens length = 2
sum = 10
doubled[3] = 8
```

`xs` が `Array` (または他の builtin コレクション) のとき、
`for x in xs { body }` は結果を**集める**。ループの値は `Array[T]`。
pull クロージャや trait イテレータは文の形なので、それに対して
`let xs = for ...` とは書けない。`ArrayBuilder` に自分で溜めること。

`for i, x in xs` はインデックスも束縛する。

## パイプ

`|>` はパイプされた値を第 1 引数として前置する。裸の `_` がスロットを
示している場合はそこへ入る。

```vibe run
fn main with Console {
  let n = "  vibe  " |> String::trim |> String::length
  let xs = [
    1,
    2,
    3
  ]
  let ys = xs |> Array::map(_, _ * 10)
  println("trimmed length = \{n}")
  println("ys[1] = \{Array::get(ys, 1)}")
}
```

```output
trimmed length = 4
ys[1] = 20
```

`xs |> Array::map(_, _ * 10)` は `Array::map(xs, (v) -> v * 10)` と読む —
1 つ目の `_` はパイプのスロット、2 つ目はセクション。

メソッド形式の `xs.length()` は型としては通る。コミットするソースでは
`Type::method(recv, args)` を好む (`vibe normalize` が復元可能なケースを
書き換える)。builtin のレシーバは `Type::method` の綴りのままで、
`Array` / `String` に裸のメソッド糖衣は無い。

次章: [等価性](16_equality.vibe.md)。
