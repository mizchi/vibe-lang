# WebAssembly Component Model Design for XS Language

## Overview

This document outlines the design for integrating WebAssembly Component Model support into the XS language, enabling type-safe composition and distribution of XS programs as reusable components.

## Goals

1. **Component Distribution** - Package XS modules as distributable WASM components
2. **Type-Safe Interfaces** - Define and enforce interfaces between components
3. **Language Interoperability** - Allow XS components to work with components from other languages
4. **Maintain XS Semantics** - Preserve functional purity and type safety across component boundaries

## Architecture

### Component Generation Pipeline

```
XS Source → AST → Type Check → IR → WASM Module → WASM Component
                                         ↓              ↑
                                    Builtin WASM    WIT Bindings
```

### Key Components

1. **WIT Generator** - Convert XS type definitions to WIT interfaces
2. **Component Builder** - Transform WASM modules into components
3. **Import/Export Mapper** - Map XS modules to component imports/exports
4. **Type Marshalling** - Convert between XS and WIT types

## Type Mapping

### Basic Types

```wit
// XS Type → WIT Type
Int        → s64
Float      → float64
Bool       → bool
String     → string
List<T>    → list<T>
```

### Complex Types

```wit
// XS ADT
type Result<T, E> = Ok(T) | Error(E)

// WIT Variant
variant result {
    ok(T),
    error(E),
}

// XS Record
type Person = { name: String, age: Int }

// WIT Record
record person {
    name: string,
    age: s64,
}
```

### Function Types

```wit
// XS Function
let add : (Int, Int) -> Int

// WIT Function
add: func(a: s64, b: s64) -> s64
```

## Implementation Plan

### Phase 1: Basic Infrastructure

1. Add dependencies:
```toml
[dependencies]
wit-bindgen = "0.35"
wasm-tools = "1.220"
wasmtime = "28.0"  # Upgrade for latest component support
```

2. Create WIT schema for XS builtins:
```wit
package xs:core@0.1.0;

interface builtins {
    // Arithmetic operations
    add: func(a: s64, b: s64) -> s64;
    sub: func(a: s64, b: s64) -> s64;
    mul: func(a: s64, b: s64) -> s64;
    div: func(a: s64, b: s64) -> s64;
    
    // Comparison
    eq: func(a: s64, b: s64) -> bool;
    lt: func(a: s64, b: s64) -> bool;
    
    // I/O
    print: func(value: string) -> string;
}
```

### Phase 2: Module to Component Mapping

Transform XS modules into components:

```lisp
(module Math
    (export add sub PI)
    (let add (fn (x y) (+ x y)))
    (let sub (fn (x y) (- x y)))
    (let PI 3.14159))
```

Generates:
```wit
package xs:user@0.1.0;

world math-component {
    export math: interface {
        add: func(x: s64, y: s64) -> s64;
        sub: func(x: s64, y: s64) -> s64;
        pi: func() -> float64;
    }
}
```

### Phase 3: Import/Export Resolution

Enable importing WASM components:

```lisp
; Import a component
(import-component "calculator:math@1.0.0" as CalcMath)

; Use imported functions
(CalcMath.sqrt 16.0)
```

### Phase 4: Type Safety

Ensure type safety across component boundaries:

1. **Static Verification** - Check WIT types match XS types at compile time
2. **Runtime Validation** - Validate data crossing component boundaries
3. **Error Handling** - Convert component errors to XS errors

## Example: Building a Component

### 1. XS Source (string-utils.xs)

```lisp
(module StringUtils
    (export concat split trim length)
    
    (let concat (fn (s1 s2) 
        (builtin-concat s1 s2)))
    
    (let split (fn (s delimiter)
        (builtin-split s delimiter)))
    
    (let trim (fn (s)
        (builtin-trim s)))
    
    (let length (fn (s)
        (builtin-length s))))
```

### 2. Generated WIT (string-utils.wit)

```wit
package xs:string-utils@0.1.0;

interface string-operations {
    concat: func(s1: string, s2: string) -> string;
    split: func(s: string, delimiter: string) -> list<string>;
    trim: func(s: string) -> string;
    length: func(s: string) -> s64;
}

world string-utils {
    export string-operations;
}
```

### 3. Component Metadata

```toml
[component]
name = "xs-string-utils"
version = "0.1.0"
authors = ["XS Language Team"]

[component.exports]
string-operations = "string-utils.wit"
```

## CLI Integration

New commands for component support:

```bash
# Build a component from XS module
xsc component build module.xs -o module.wasm

# Generate WIT from XS module
xsc component wit module.xs -o module.wit

# Validate component interface
xsc component validate module.wasm

# Compose multiple components
xsc component compose app.xs --with math.wasm --with string.wasm
```

## Runtime Considerations

### Memory Management

- Components have isolated memory
- Data crossing boundaries must be copied
- Consider shared memory for large data (future)

### Performance

- Minimize cross-component calls
- Batch operations when possible
- Use native WASM types for efficiency

### Security

- Components run in isolation
- Capability-based security model
- No ambient authority

## Future Enhancements

1. **Streaming Data** - Support for async streams between components
2. **Resource Types** - Handle resources (files, sockets) across components
3. **Component Registry** - Package manager for XS components
4. **Visual Composition** - GUI for connecting components

## Testing Strategy

1. **Unit Tests** - Test individual component functions
2. **Integration Tests** - Test component composition
3. **Compatibility Tests** - Test with components from other languages
4. **Performance Tests** - Measure overhead of component boundaries

## Migration Path

For existing XS code:

1. Identify module boundaries
2. Define WIT interfaces
3. Generate components
4. Update imports to use components
5. Test thoroughly

## Success Metrics

- Successfully compose XS components with Rust/Python components
- < 5% performance overhead for component calls
- Type-safe interfaces prevent runtime errors
- Components under 100KB for typical modules

## Conclusion

WebAssembly Component Model support will enable XS to participate in the growing WASM ecosystem while maintaining its core values of type safety and functional purity. This design provides a path to building and distributing reusable XS components that work seamlessly with components from other languages.