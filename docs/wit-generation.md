# WebAssembly Interface Types (WIT) Generation

XS Language now supports automatic generation of WIT interfaces from XS modules, enabling seamless integration with the WebAssembly Component Model.

## Usage

Generate a WIT interface from an XS module:

```bash
xsc component wit <module.xs> [-o output.wit]
```

## Example

Given an XS module:

```lisp
(module Math
  (export add subtract multiply divide)
  
  (let add (fn (x y) (+ x y)))
  (let subtract (fn (x y) (- x y)))
  (let multiply (fn (x y) (* x y)))
  (let divide (fn (x y) (/ x y))))
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

world math {
  export exports;
}
```

## Type Mappings

| XS Type | WIT Type |
|---------|----------|
| Int | s64 |
| Float | float64 |
| Bool | bool |
| String | string |
| List a | list<T> |
| Function | func(...) |

## Features

- Automatic type inference for exported functions
- Support for curried functions (automatically uncurried in WIT)
- Package naming based on module file name
- Version specification support

## Future Work

- Support for algebraic data types (ADTs) as WIT variants
- Component building (compile to .wasm component)
- Import interface generation
- Resource types for stateful components