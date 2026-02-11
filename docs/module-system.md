# xsh Module System (現行仕様)

## 目的
- ユーザー向けには `::` で統一された名前空間アクセスを提供する。
- 実装内部の解決/再配置は parser lower で吸収し、利用側 API はシンプルに保つ。

## 構文

### モジュール定義
```xsh
module math {
  let private_inc = (x: Int) -> Int { add(x, 1) }
  export let inc = private_inc
}
```

```xsh
export module math {
  export let inc = (x: Int) -> Int { add(x, 1) }
}
```

### モジュール import
```xsh
import { module math } from ./lib.xm
math::inc(41)
```

```xsh
import { module math as m } from ./lib.xm
m::inc(41)
```

## 意味論
- `module foo { ... }` は内部的に `foo::name` 形式へ lower される。
- `export module foo { ... }` は `foo::...` を export する。
- `import { module foo } from ...` は対象 module の export から `foo::` prefix を持つ値を一括取り込みする。
- アクセス子は `::` を正規とする。

## import kind
- `import { x }`: `value`
- `import { type T }`: `type`
- `import { trait Eq }`: `trait`
- `import { module foo }`: `module` (namespace import)

## 制約 (現行)
- `import { module foo::bar }` は未対応 (parse error)。
- `module` 本体は現状、以下の文のみを想定:
  - `let` / `export let` / `let mut`
  - 代入、式文、`import`
  - `test` / `bench`
- 空モジュールは parse error。
- `import { module ... }` は `.xm` ソースに限定 (`.xsh` では import error)。

## 例
```xsh
// lib.xm
export module math {
  export let inc = (x: Int) -> Int { add(x, 1) }
}

// main.xsh
import { module math } from ./lib.xm
let v = math::inc(1)
```

## 今後の拡張候補
- module 本体で許可する statement の拡張
- module import の wasm import 連携方針の整理
