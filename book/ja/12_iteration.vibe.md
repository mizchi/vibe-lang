# 12 — 反復

前: [コレクション](11_collections.vibe.md)

English version: [12_iteration.vibe.md](../en/12_iteration.vibe.md)

vibe の反復はほとんどが「配列を一度なめる eager な一巡」で済む。この章は
その一巡と、それをつなぐ `|>` 演算子、そして相手が「すでに手元にある
コレクション」でない場合にどこを見るか。

## 配列を一度なめる

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

`for x in xs { body }` は**集める**。`xs` が `Array`（または他の組み込み
コレクション）なら、このループは式で、その値は `Array[T]` になる。だから
`doubled` は添字で引ける。`for i, x in xs` と書けば添字も束縛される。

`Array::map` / `Array::filter` / `Array::fold` は同じ仕事を関数として
行う。呼び出し側で読みやすい方を選べばよく、どちらも同じ一巡。

## パイプ

`|>` は左側の値を右側の第一引数として渡す。裸の `_` で位置を指定した場合は
そこに入る。

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

`xs |> Array::map(_, _ * 10)` は `Array::map(xs, (v) -> v * 10)` と読む。
2つの `_` は別物で、1つ目はパイプの差し込み位置、2つ目はセクション —
その引数についてのラムダの略記。

## 配列でない場合

組み立てるべき遅延コンビネータの鎖は無い。`Array::*` の呼び出しと `for`
が eager 層であり、それで全部。

もう一つの層は、値が時間をかけて届く場合 — ストリーム、ソケット、分割して
読むファイル。そこでは手元にコレクションが無いので pull する。`next` が
中断しうるイテレータになる。中断は専用のループ構文ではなく effect row が
運ぶので、`for await` のような別形は存在しない。
[並行性](17_concurrency.vibe.md) を参照。

次: [エフェクト](13_effects.vibe.md)。
