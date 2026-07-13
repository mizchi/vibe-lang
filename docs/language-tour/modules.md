# Modules

vibe uses file-based modules with explicit `export` / `import`.

## export

Mark bindings for external use with `export`.

```vibe
// math.vibe
export let double: (Int) -> Int = (x) -> { x * 2 }
export let triple: (Int) -> Int = (x) -> { x * 3 }

// Batch export
export { double, triple }

// Export types and traits
export enum Color { Red; Green; Blue }
export struct Point { x: Int; y: Int }
export open trait Show
```

Non-exported bindings are private to the file.

## import

Import bindings from another file with `import`.

<!-- doctest-skip: 対になる math.vibe が実ファイルとして存在しない 2 ファイル例 (#831: 欠落 import は raw crash) -->
```vibe skip
// main.vibe
import ./math.vibe { double, triple }

test "import" {
  assert(eq(double(5), 10))
}
```

### Renaming imports

<!-- doctest-skip: 存在しない import 先 (./math.vibe) を参照する構文例 -->
```vibe skip
import ./math.vibe { double as dbl }
```

### Import kinds

<!-- doctest-skip: 存在しない import 先 + `module` import kind は #728 で削除済み (このセクションは stale、要更新) -->
```vibe skip
import ./types.vibe { type MyType }     // type import
import ./traits.vibe { trait Show }     // trait import
import ./lib.xm { module math }         // module namespace import
```

## module blocks

> **REMOVED (#728, ADR-0063)**: `module { ... }` blocks are no longer part of
> the language — use file boundaries + `import`/`export`. The examples below
> are kept for historical context only.

<!-- doctest-skip: module block は #728/ADR-0063 で削除済み (parser が located error で reject) -->
```vibe skip
module math {
  export let inc: (Int) -> Int = (x) -> { x + 1 }
}

test "module" {
  assert(eq(math::inc(41), 42))
}
```

Export a module for use from other files:

<!-- doctest-skip: module block は #728/ADR-0063 で削除済み -->
```vibe skip
// lib.xm
export module math {
  export let inc: (Int) -> Int = (x) -> { x + 1 }
}
```

<!-- doctest-skip: `module` import kind は #728 で削除済み + 存在しない import 先 -->
```vibe skip
// main.vibe
import ./lib.xm { module math }

math::inc(41)  // => 42
```

### Module with alias

<!-- doctest-skip: `module` import kind は #728 で削除済み + 存在しない import 先 -->
```vibe skip
import ./lib.xm { module math as m }

m::inc(41)
```

## PinnedPath imports

Pin imports to a specific content hash for reproducible builds:

<!-- doctest-skip: `./dep.vibe#hash` の PinnedPath suffix は現 parser 未対応 (unknown # directive) — spec と実装の gap -->
```vibe skip
import ./dep.vibe#a1b2c3d { helper }
```

The `#hash` suffix ensures the import resolves to a known version,
independent of lock files.

## extern (FFI)

Declare external function signatures without implementation.

```vibe
extern let %parse_json: (String) -> Json with { Error }
```

`extern` symbols use `%`-prefixed reserved names to avoid collisions.

## File conventions

- `.vibe` -- standard source files
- `.xm` -- module-oriented files (for `module` exports)
- Each directory uses `index.vibe` as the public endpoint
- `index.lock` -- dependency lock file per directory
- `.vibe/cache.json` -- namespace/graph cache
