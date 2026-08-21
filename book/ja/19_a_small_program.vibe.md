# 2 — 小さなプログラム

English version: [19_a_small_program.vibe.md](../en/19_a_small_program.vibe.md) (canonical)

Rust book は hello-world のあとで一度立ち止まり、数当てゲームを書く。この章が
その枠にあたる。struct、`Option`、`MutMap`、そして自分に必要なものを述べる
`fn` を使って、リスト中の単語を数える。まだ見ていない構文もある。それが狙い。

```vibe run
import @vibe/core {
  struct MutMap, MutMap::get, MutMap::new_string, MutMap::set, MutMap::size
}

struct Tally {
  word: String; count: Int
} derive (Show)

fn bump(m: MutMap[String, Int], word: String) -> Unit {
  let n = match MutMap::get(m, word) {
    Some(v) => v + 1,
    None => 1
  }
  MutMap::set(m, word, n)
}

fn count_of(m: MutMap[String, Int], word: String) -> Int {
  match MutMap::get(m, word) {
    Some(v) => v,
    None => 0
  }
}

fn top_word(words: Array[String]) -> Tally {
  let m: MutMap[String, Int] = MutMap::new_string()
  let mut i = 0
  while i < Array::length(words) {
    bump(m, Array::get(words, i))
    i = i + 1
  }
  let mut best = Tally::{
    word: "", count: 0
  }
  i = 0
  while i < Array::length(words) {
    let w = Array::get(words, i)
    let n = count_of(m, w)
    if n > best.count {
      best = Tally::{
        word: w, count: n
      }
    } else {
      ()
    }
    i = i + 1
  }
  best
}

fn main with Console {
  let words = [
    "vibe",
    "wasm",
    "vibe",
    "row",
    "vibe",
    "wasm"
  ]
  let top = top_word(words)
  let kinds: MutMap[String, Int] = MutMap::new_string()
  let mut i = 0
  while i < Array::length(words) {
    bump(kinds, Array::get(words, i))
    i = i + 1
  }
  println("top = \{top}")
  println("kinds = \{MutMap::size(kinds)}")
}
```

```output
top = Tally { word: vibe, count: 3 }
kinds = 3
```

このプログラムが意図して見せているもの:

- `fn main with Console` が、このプログラムに必要な唯一の capability。
- 意味の一部としての失敗なら `Result` ラッパではなく `with Exception` に
  なる。キーが無いことは `Option` で表し、`match` で開く。
- ミューテーションは関数の中に留まる (`let mut i`、`MutMap` のハンドル)。
  何も逃げ出さない。

まだ小さなプログラムのままでできる次の一歩: `top_word` を独立したファイルの
ライブラリ関数にして export し、[モジュール](07_modules_packages.vibe.md) が
やっているように `fn main` から import する。

次章: [値と関数](01_values_functions.vibe.md)。
