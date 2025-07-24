# WebAssembly Component Model

Vibe Language can compile to WebAssembly components, enabling type-safe composition and interoperability with other WebAssembly modules.

## Overview

The Component Model allows you to:
- Export Vibe modules as WebAssembly components
- Generate WIT (WebAssembly Interface Types) interfaces
- Compose with components written in other languages

## Building Components

```bash
# Generate a WebAssembly component
vsh component build module.vibe -o module.wasm

# Generate WIT interface
vsh component wit module.vibe -o module.wit
```

## Example

Given a Vibe module:

```haskell
module Math {
  export add, subtract, multiply, divide
  
  let add x y = x + y
  let subtract x y = x - y
  let multiply x y = x * y
  let divide x y = x / y
}
```

The generated WIT interface:

```wit
package vibe:math@0.1.0;

interface exports {
  add: func(x: s64, y: s64) -> s64;
  subtract: func(x: s64, y: s64) -> s64;
  multiply: func(x: s64, y: s64) -> s64;
  divide: func(x: s64, y: s64) -> s64;
}
```

## Type Mapping

| Vibe Type | WIT Type |
|-----------|----------|
| Int       | s64      |
| Float     | float64  |
| Bool      | bool     |
| String    | string   |
| List a    | list<T>  |

## Limitations

- Only pure functions can be exported
- Effects must be handled before export
- Recursive types have limited support