# Show Trait Design: DCE-safe value display

## 問題

REPL/shell で値を表示するために各型に `to_string` を実装すると、
`vibe build` / `vibe run` でもバイナリに含まれてサイズが膨れる。

## 設計方針

### 1. to_string は通常の関数

```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented
// prelude/show.vibe
let Int::to_string = (n: Int) -> String { ... }
let Array::to_string = (arr: Array[T]) -> String { ... }
let Option::to_string = (opt: Option[T]) -> String { ... }
```

特別なランタイムマジックは使わない。通常の関数として定義し、
呼び出されなければ DCE (Dead Code Elimination) で除去される。

### 2. REPL のみが to_string を呼ぶ

- `vibe shell` / `vibe shell-stdin`: 最終値の表示に `to_string` を呼ぶ
- `vibe run`: `last: <value>` 表示時にのみ呼ぶ
- `vibe build`: to_string を参照しなければ DCE で除去
- `vibe build --release`: 最大限の DCE

### 3. show_value ヘルパー

```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented
// コンパイラが自動生成する show_value 関数
// REPL モードでのみバンドルに含まれる
let show_value = (tagged: Int) -> String {
  let tag = tagged & 3
  if tag == 0 { return Int::to_string(tagged >> 2) }
  if tag == 3 { return if tagged >> 2 != 0 { "true" } else { "false" } }
  // heap object
  let ty = memory_load_i32(tagged & ~3, 0)
  match ty {
    1 => // String: return as-is
    5 => // Array: Array::to_string(...)
    6 => // Map: Map::to_string(...)
    9 => // Double: Double::to_string(...)
    10 => // Enum: Enum::to_string(...)
    _ => "<opaque>"
  }
}
```

### 4. DCE との統合

- `show_value` は REPL ラッパーからのみ呼ばれる
- `vibe build` で REPL ラッパーがなければ、`show_value` とそこから呼ばれる
  `Int::to_string`, `Array::to_string` 等は全て DCE で除去される
- `--include-show` フラグで明示的にバンドルに含めることも可能

### 5. 段階的実装

| Phase | 内容 |
|-------|------|
| Phase 0 (現状) | Node.js runner でメモリを直接読む |
| Phase 1 | prelude に to_string 関数群を追加、REPL で呼び出し |
| Phase 2 | Show trait を定義、derive(Show) で自動生成 |
| Phase 3 | ユーザー定義型にも Show impl を許可 (#37 依存) |

Phase 0 → 1 は trait なしで実装可能。Phase 2-3 は #37 (trait body) 依存。
