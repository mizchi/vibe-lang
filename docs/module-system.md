# vibe Module System (現行仕様)

## 目的
- ユーザー向けには `::` で統一された名前空間アクセスを提供する。
- 実装内部の解決/再配置は parser lower で吸収し、利用側 API はシンプルに保つ。

## 構文

### モジュール定義
```vibe
module math {
  let private_inc = (x: Int) -> Int { add(x, 1) }
  export let inc = private_inc
}
```

```vibe
export module math {
  export let inc = (x: Int) -> Int { add(x, 1) }
}
```

### モジュール import / use
```vibe
use ./lib.xm { module math }
math::inc(41)
```

```vibe
use ./lib.xm { module math as m }
m::inc(41)
```

```vibe
use /vibe/std/string
std/string::from_char_code(65)
```

## 意味論
- `module foo { ... }` は内部的に `foo::name` 形式へ lower される。
- `export module foo { ... }` は `foo::...` を export する。
- `use <path> { ... }` は Rust 風に source 先行で import できる。
- `use <path>` は namespace import の省略形。
- `/vibe/...` の場合は `/vibe/` を落とした名前空間を使う（例: `/vibe/std/string` -> `std/string::...`）。
- `import { ... } from ...` は廃止され、parse error になる。
- `module` import は `.xm` ソースのみ対応し、`foo::...` 形式 export を取り込む。
- アクセス子は `::` を正規とする。

## import kind
- `use <path> { x }`: `value`
- `use <path> { type T }`: `type`
- `use <path> { trait Eq }`: `trait`
- `use <path> { module foo }`: `module` (namespace import)

## 制約 (現行)
- `use <path> { module foo::bar }` は未対応 (parse error)。
- `module` 本体は現状、以下の文のみを想定:
  - `let` / `export let` / `let mut`
  - 代入、式文、`import`
  - `test` / `bench`
- 空モジュールは parse error。

## 例
```vibe
// lib.xm
export module math {
  export let inc = (x: Int) -> Int { add(x, 1) }
}

// main.vibe
use ./lib.xm { module math }
let v = math::inc(1)
```

## 今後の拡張候補
- module 本体で許可する statement の拡張
- module import の wasm import 連携方針の整理
