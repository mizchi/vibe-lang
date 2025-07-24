# XS Language Effect System Guide

## Overview

XS言語のエフェクトシステムは、KokaやUnisonに影響を受けた拡張可能エフェクトシステムです。副作用を型レベルで追跡し、純粋な関数と副作用のある計算を明確に区別できます。

## Current Implementation Status

### ✅ Implemented
- Basic effect syntax (`perform`)
- Effect types in the type system
- Parser support for effect keywords
- Basic type checking for effects
- Built-in effects (IO, State, Exception, Async)

### ⚠️ Partially Implemented
- Runtime evaluation of effects (only `perform print` works)
- Effect handlers (syntax recognized but not evaluated)
- Do notation (syntax recognized but not evaluated)

### ❌ Not Yet Implemented
- Full effect handler evaluation
- Effect inference
- Effect polymorphism
- With-handler semantics

## Basic Syntax

### 1. Performing Effects

**Currently Working:**
```haskell
-- Print effect (the only one that works at runtime)
perform print "Hello, World!"
```

**Recognized by Parser but Not Evaluated:**
```haskell
-- IO effect
perform IO "Hello, World!"

-- State effect  
perform State ()

-- Exception effect
perform Exception "Error message"

-- Async effect
perform Async 42
```

### 2. Effects in Functions

```haskell
-- Function with IO effect
let printMessage = fn msg -> perform IO msg

-- Function with State effect
let getCounter = fn unit -> perform State ()

-- Function with Exception effect
let throwError = fn msg -> perform Exception msg
```

### 3. Type Annotations with Effects

Currently, the type system recognizes effects but explicit effect annotations in types are not fully supported:

```haskell
-- Future syntax (not yet working):
-- printInt : Int -> IO ()
-- readAndPrint : () -> {IO, Exception<String>} String
```

### 4. Pattern Matching with Effects

Effects can be used in pattern matching branches:

```haskell
match someList {
  [] -> perform IO "Empty list"
  x :: xs -> perform IO "Non-empty list"
}
```

### 5. Conditional Effects

Effects in if-then-else expressions:

```haskell
if condition {
  perform IO "True branch"
} else {
  perform IO "False branch"
}
```

## Built-in Effects

### IO Effect
- Used for input/output operations
- Operations: print, read (planned)

### State Effect
- Used for stateful computations
- Operations: get, put (planned)

### Exception Effect
- Used for error handling
- Operations: throw (catch planned)

### Async Effect
- Used for asynchronous computations
- Operations: async, await (planned)

## Current Limitations

1. **Limited Runtime Support**: Only `perform print` works at runtime (not `perform IO`)
2. **No Effect Handlers**: Handler syntax is parsed but not evaluated
3. **No Effect Inference**: Effects must be explicit
4. **No Effect Polymorphism**: Generic effect variables not supported
5. **Effect Names**: Must use exact effect names (e.g., `print` not `IO`)

## Examples

### Working Example

```haskell
-- This works
perform print "Hello, World!"

-- Multiple prints
perform print "Line 1"
perform print "Line 2"

-- Print returns Unit
let result = perform print "Message"
-- result is Unit
```

### Future Examples (Not Yet Working)

```haskell
-- Effect handlers (parsed but not evaluated)
handle computation with
  | State.get () resume -> resume initialState initialState
  | State.put newState resume -> resume () newState
  | return x state -> (x, state)
end

-- Do notation (parsed but not evaluated)
do IO {
  line <- perform IO.read
  perform IO.print (String.toUpper line)
}

-- Effect polymorphism (not implemented)
map : forall a b e. (a -> e b) -> List a -> e (List b)
```

## Type Checking

The type checker recognizes effects but doesn't enforce them strictly yet. This means:

1. Effects are parsed and stored in the AST
2. Basic type checking passes for effect expressions
3. Effect propagation and inference are not implemented
4. Effect handlers don't eliminate effects from types

## Best Practices

1. **Use effects explicitly**: Always use `perform` for side effects
2. **Keep effects at the edges**: Try to keep pure functions pure
3. **Document effects**: Comment about expected effects until type annotations work
4. **Test pure functions**: Focus testing on pure functions

## Future Roadmap

1. Complete runtime evaluation of all built-in effects
2. Implement effect handler evaluation
3. Add effect inference to type checker
4. Support effect polymorphism
5. Add effect annotations in type signatures
6. Implement effect rows and row polymorphism