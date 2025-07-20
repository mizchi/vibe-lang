# WebAssembly Component Model Support

XS Language provides experimental support for WebAssembly Component Model, enabling type-safe composition and interoperability with other WebAssembly components.

## Overview

The Component Model allows you to:
- Export XS modules as WebAssembly components
- Generate WIT (WebAssembly Interface Types) interfaces from XS modules
- Compose XS components with components written in other languages

## Generating WIT Interfaces

To generate a WIT interface from an XS module:

```bash
# Output to stdout
xsc component wit module.xs

# Output to file
xsc component wit module.xs -o module.wit
```

### Example

Given an XS module:

```lisp
(module Math
  (export add subtract multiply divide)
  
  (let add (fn (x y) (+ x y)))
  (let subtract (fn (x y) (- x y)))
  (let multiply (fn (x y) (* x y)))
  (let divide (fn (x y) (/ x y)))
)
```

The generated WIT interface will be:

```wit
package xs:math@0.1.0;

interface exports {
  add: func(arg1: s64, arg2: s64) -> s64;
  subtract: func(arg1: s64, arg2: s64) -> s64;
  multiply: func(arg1: s64, arg2: s64) -> s64;
  divide: func(arg1: s64, arg2: s64) -> s64;
}

world xs:math {
  export exports;
}
```

## Type Mapping

XS types are mapped to WIT types as follows:

| XS Type | WIT Type |
|---------|----------|
| Int | s64 |
| Float | float64 |
| Bool | bool |
| String | string |
| List a | list<a> |
| Function | (handled separately) |
| User-defined types | (placeholder: string) |

### Function Types

XS functions with automatic currying are unwrapped to extract all parameters:

- `(fn (x y) ...)` → `func(arg1: T1, arg2: T2) -> R`
- `(fn (x) (fn (y) ...))` → `func(arg1: T1, arg2: T2) -> R`

## Building Components

Component building requires integration with wasm-tools:

```bash
xsc component build module.xs -o module.wasm
```

**Note**: This feature is not yet fully implemented and requires wasm-tools integration.

## Current Limitations

1. **Type Inference**: Complex type inference may not always produce accurate WIT types
2. **User-Defined Types**: ADTs are currently mapped to string placeholders
3. **Effect Types**: Effect types are not yet represented in WIT
4. **Component Building**: Full component building requires wasm-tools integration
5. **Imports**: Component imports are not yet supported

## Future Enhancements

- Full ADT support in WIT generation
- Component composition support
- wit-bindgen integration for generating bindings
- Support for resource types
- Component imports and exports