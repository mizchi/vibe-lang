# 19 — A small program

The Rust book pauses after the basics to write a guessing game. Here
is the vibe equivalent: tally words in a list, using a struct, an
`Option`, a `MutMap`, and a `fn` that says what it needs.

```vibe run
import @vibe/prelude {
  stdout_write
}
import @vibe/core {
  type MutMap, MutMap::get, MutMap::new_string, MutMap::set, MutMap::size
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

fn main with Stdout {
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
  stdout_write("top = \{top}\n")
  stdout_write("kinds = \{MutMap::size(kinds)}\n")
}
```

```output
top = Tally { word: vibe, count: 3 }
kinds = 3
```

What this program is deliberately showing:

- `fn main with Stdout` is the only capability the program needs.
- Failure that is part of the meaning would be `with Exception`, not
  a `Result` wrapper. Absence of a key is `Option`, unwrapped with
  `match`.
- Mutation stays in the function (`let mut i`, a `MutMap` handle).
  Nothing escapes.

A next step that is still a small program: turn `top_word` into a
library function in its own file, export it, and import it from
`fn main` the way [Modules](07_modules_packages.vibe.md) does.

Next: [Capabilities](10_capabilities.vibe.md).
