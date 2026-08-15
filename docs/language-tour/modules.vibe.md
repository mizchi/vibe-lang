# Modules

vibe uses file-based modules with explicit `export` / `import`. This page
covers the surface syntax. **The rules for package boundaries, visibility and
pinning are stated once, in the "現行モデル" section of
[docs/module-system-oracle.md](../module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)**
(#1269) -- read that as the source of truth, and treat anything here that
disagrees with it as a bug in this page.

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

Importing a directory resolves to its index. The **boundary** -- what other
packages may reach -- is `index.vpkg`; see the oracle section linked at the top.

```vibe skip
import ./subdir { helper }   // resolves to subdir's index
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

## Contract files (`index.vpkg`)

A package's public API is declared in `index.vpkg`: a `name` / `version` /
`description` / `deps` / `generated_hash` header (ADR-0080) followed by
body-less declarations, whose implementations live in sibling `.vibe` files and
are checked against the contract.

| File | Meaning |
|---|---|
| `index.vpkg` | The contract, and **the only package boundary**. Body-less declarations; the header declares dependency versions. |
| `index.vibe` | A package entry / facade. Convenient, but **not** a boundary. |
| `index.vibei` | Legacy. Not a boundary, and no longer present in this repository. |

Two index spellings in one directory is a hard error. For visibility, implicit
build roots and the exact effect of each spelling, see the oracle section linked
at the top.

## require (content-addressed dependencies)

Dependencies are pinned by content hash, not a separate lock file:

```vibe skip
require @vibe/core 1.2.3 = #ab12cd34      // bare triple = exact match
require @vibe/http ^1.2.3 = #77aa02ef     // ^ = compatible range
```

`vibe fmt` inserts and verifies the `= #hash` suffix from the local store.
Resolution order, `deps` versus `require`, and `VIBE_REQUIRE_PINS` are in the
oracle section linked at the top.

## extern (FFI)

Declare external function signatures without implementation.

```vibe
extern let %parse_json: (String) -> Json with Exception
```

`extern` symbols use `%`-prefixed reserved names to avoid collisions.

## File conventions

- `.vibe` -- standard source files
- `.vpkg` -- contract file (body-less declarations, checked against sibling `.vibe` implementations)
- `index.vpkg` is the public boundary of a package; `index.vibe` is an entry, not a boundary
- `require NAME VERSION = #hash` lines are the manifest *and* the lock (no separate lock file)
