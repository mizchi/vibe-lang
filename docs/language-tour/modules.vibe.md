# Modules

vibe uses file-based modules with explicit `export` / `import`. Module
System v2 (ADR-0063 / ADR-0064,
[docs/module-system-v2.md](../module-system-v2.md)) governs the current
rules: directories with an `index.vibe`/`index.vibei` are boundaries, and
content-addressed `require` pins replace lock files.

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

```vibe skip
// main.vibe
import ./math.vibe { double, triple }

test "import" {
  assert(eq(double(5), 10))
}
```

### Renaming imports

```vibe skip
import ./math.vibe { double as dbl }
```

### Type and trait imports

```vibe skip
import ./types.vibe { type MyType }     // type import
import ./traits.vibe { trait Show }     // trait import
```

### Directory imports

A directory with an `index.vibe`/`index.vibei` is a **boundary**: importing
the directory resolves to its index, and files *inside* the directory can
only be reached from outside through names the index exports.

```vibe skip
import ./subdir { helper }   // resolves to subdir/index.vibe(i)
import . { helper }          // this directory's own index
```

## Re-exporting

An index can re-export names from a sibling file in the same directory:

```vibe skip
// index.vibe
export ./lib.vibe { helper1, helper2 }
```

Wildcard re-export is intentionally not supported — every re-exported name
is listed explicitly.

## Contract files (`.vibei`)

A directory's public API can be declared as a separate, body-less contract
file instead of inline in `index.vibe`:

| File | Meaning |
|---|---|
| `index.vibe` | Declarations have bodies (implementation inline). Good for small packages/scripts. |
| `index.vibei` | Declarations have **no bodies** — implementation lives in sibling `.vibe` files and is checked against the contract. |

A directory may have `index.vibe` *or* `index.vibei`, never both. See
[docs/module-system-v2.md §3](../module-system-v2.md) for the full rules
(opaque types, effect rows as contract surface, `where` clauses).

## require (content-addressed dependencies)

Dependencies are pinned by content hash, not a separate lock file:

```vibe skip
require @vibe/core 1.2.3 = #ab12cd34      // bare triple = exact match
require @vibe/http ^1.2.3 = #77aa02ef     // ^ = compatible range
```

`vibe fmt` inserts/verifies the `= #hash` suffix from the local store. See
[docs/module-system-v2.md §6](../module-system-v2.md) for the full
resolution and override rules.

## extern (FFI)

Declare external function signatures without implementation.

```vibe
extern let %parse_json: (String) -> Json with Exception
```

`extern` symbols use `%`-prefixed reserved names to avoid collisions.

## File conventions

- `.vibe` -- standard source files
- `.vibei` -- contract file (body-less declarations, checked against sibling `.vibe` implementations)
- Each directory uses `index.vibe`/`index.vibei` as the public boundary
- `require NAME VERSION = #hash` lines are the manifest *and* the lock (no separate lock file)
