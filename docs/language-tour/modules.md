# Modules

vibe uses file-based modules with explicit `export` / `import`.

## export

Mark bindings for external use with `export`.

```vibe
// math.vibe
export let double = (x: Int) -> Int { x * 2 }
export let triple = (x: Int) -> Int { x * 3 }

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

```vibe
// main.vibe
import ./math.vibe { double, triple }

test "import" {
  assert(eq(double(5), 10))
}
```

### Renaming imports

```vibe
import ./math.vibe { double as dbl }
```

### Import kinds

```vibe
import ./types.vibe { type MyType }     // type import
import ./traits.vibe { trait Show }     // trait import
import ./lib.xm { module math }         // module namespace import
```

## module blocks

Group related definitions into a namespace accessed with `::`.

```vibe
module math {
  export let inc = (x: Int) -> Int { x + 1 }
}

test "module" {
  assert(eq(math::inc(41), 42))
}
```

Export a module for use from other files:

```vibe
// lib.xm
export module math {
  export let inc = (x: Int) -> Int { x + 1 }
}
```

```vibe
// main.vibe
import ./lib.xm { module math }

math::inc(41)  // => 42
```

### Module with alias

```vibe
import ./lib.xm { module math as m }

m::inc(41)
```

## PinnedPath imports

Pin imports to a specific content hash for reproducible builds:

```vibe
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
