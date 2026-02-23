# Modules

vibe uses file-based modules with explicit `export` / `use`.

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

## use (import)

Import bindings from another file with `use`.

```vibe
// main.vibe
use ./math.vibe { double, triple }

test "import" {
  assert(eq(double(5), 10))
}
```

### Renaming imports

```vibe
use ./math.vibe { double as dbl }
```

### Import kinds

```vibe
use ./types.vibe { type MyType }     // type import
use ./traits.vibe { trait Show }     // trait import
use ./lib.xm { module math }        // module namespace import
```

## module blocks

Group related definitions into a namespace accessed with `::`.

```vibe
module math {
  export let inc = (x: Int) -> Int { x + 1 }
}

math::inc(41)  // => 42
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
use ./lib.xm { module math }
math::inc(41)  // => 42
```

### Module with alias

```vibe
use ./lib.xm { module math as m }
m::inc(41)
```

## declare (FFI)

Declare external function signatures without implementation.

```vibe
declare export let parse_json: (String) -> Json with { Error }
```

`declare` and implementation must match effect annotations:

```vibe
declare export let f: (String) -> Int with { Error }
f = (s: String) -> Int with { Error } { string_length(s) }
```

## File conventions

- `.vibe` -- standard source files
- `.xm` -- module-oriented files (for `module` exports)
- Each directory can have an `index.vibe` with `export let version = "..."` for package identity
