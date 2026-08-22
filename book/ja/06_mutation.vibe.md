# 06 — ミューテーション・region・エスケープ

前: [型と文字列](05_types_strings.vibe.md)

English version: [06_mutation.vibe.md](../en/06_mutation.vibe.md)

vibe は既定で不変で、ミューテーションは意図的に小さく作られています。局所的
であり、関数の effect row には決して現れません。内部でカウンタを使う関数の
署名は使わない関数と同じです — 外から見て違いがないからです。

## カウンタ

`let mut` は、そのブロックが終わるまで書き換え可能な束縛を作ります:

```vibe run
fn main with Console {
  let y = {
    let mut v = 0
    v += 1
    v + 1
  }
  println("y = \{y}")
}
```

```output
y = 2
```

`y` はただの不変な `Int` です。可変な束縛は波括弧の中にしか存在せず、
コンパイラはそれをマシンのレジスタに置きます。

## 配列を伸ばす

ここでは**束縛**が不変で**中身**が伸びます。`Array::push` はその場で追加
するので、その配列を指すすべての名前が新しい要素を見ます — 渡した先の関数を
含めて:

```vibe run
fn grow(xs: Array[Int]) -> Unit {
  Array::push(xs, 9)
}

fn main with Console {
  let xs = [
    1
  ]
  grow(xs)
  println("length = \{Array::length(xs)}, last = \{Array::get(xs, 1)}")
}
```

```output
length = 2, last = 9
```

ここは意識しておく価値があります。`xs` は共有であってコピーではありません。
自分専用のコピーが欲しければ、明示的に作ってください。

## 書き込めるフィールド

変わるものが値の一部なら、そのフィールドを `mut` と宣言します。書き込みは
すべてのエイリアスから観測されます — 書き込み前に取ったものも含めて:

```vibe run
struct Counter {
  mut n: Int
} derive (Show)

fn bump(c: Counter) -> Unit {
  c.n = c.n + 1
}

fn main with Console {
  let c = Counter::{
    n: 10
  }
  let alias = c
  bump(c)
  bump(c)
  println("c.n = \{c.n}, alias.n = \{alias.n}")
}
```

```output
c.n = 12, alias.n = 12
```

ローカルで済むなら `let mut` を選んでください。`mut` フィールドは、その値を
持っている誰もが書き込めるセルであり、カウンタよりずっと大きな主張です。

## エスケープとは捕獲のこと

`let mut` が本当にローカルかどうかを決める規則は1つです。束縛より長生き
しうるクロージャがそれを捕獲したら、もうローカルではありません。その場合
コンパイラは、クロージャから届くようにヒープへ置きます。

どの束縛がそうなったかを当てる必要はありません:

```bash
vibe escapes file.vibe
```

エスケープする `let mut` を1件1行で出力し、出力が空ならファイル中の
`let mut` はすべてただのローカルです。もう1つの形式があります:

```bash
vibe escapes --strict file.vibe
```

既定は「codegen が何をするか」に答えます — 迷ったら box するので、既定は
多めに報告します。`--strict` は「そのクロージャが本当にこの束縛に届くか」に
答え、名前が単にシャドウされているだけの場合を差し引きます。コストが気に
なるなら既定を、誰が何を書けるかが気になるなら `--strict` を訊いてください。

## Region

並行処理では同じ考えのより強い版が要ります。タスクグループに属する作業用の
値は、グループより長生きしてはいけません。`TaskGroup::run` はそのために
新しい region タグを作り、本体の戻り値を通じて値が抜け出すのを拒否します。
機構が意味を持つ場所、[並行処理](17_concurrency.vibe.md)で扱います。

## どれを選ぶか

一通り見た上で:

| やりたいこと | 使うもの |
|---|---|
| 1つの関数の中のカウンタや累算器 | `let mut` |
| 配列を組み立ててから読む | `ArrayBuilder` を freeze する |
| テキストを組み立てる | `StringBuilder` |
| フィールドが時間とともに変わる値 | `struct S { mut f: T }` |
| 呼び出しをまたぐ、仲介された状態 | effect と `handle` |

大半のコードは1行目で足ります。ビルダーは
[コレクション](13_collections.vibe.md)で扱います。

次: [構造体・列挙・match](07_data.vibe.md)。
