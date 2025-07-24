# Vibe Language Effect System Guide

## Overview

Vibe's effect system tracks side effects at the type level, distinguishing pure functions from effectful computations. The system is inspired by languages like Koka and Unison.

## Current Status

### ✅ Working
- Basic effect syntax (`perform`)
- Effect types in type signatures
- Built-in effects (IO, State, Error, Async)
- Effect inference for simple cases

### ⚠️ Partial Implementation
- Effect handlers (syntax recognized, evaluation limited)
- Do notation (basic support)
- Effect polymorphism

## Basic Usage

### Performing Effects

```haskell
-- IO effect
let greet name = perform IO.print ("Hello, " ++ name)

-- Function type includes effect
-- greet : String -> IO Unit
```

### Pure vs Effectful Functions

```haskell
-- Pure function (no effects)
let add x y = x + y
-- add : Int -> Int -> Int

-- Effectful function
let printSum x y = perform IO.print (intToString (x + y))
-- printSum : Int -> Int -> IO Unit
```

### Multiple Effects

```haskell
-- Function using multiple effects
let readAndPrint = 
  perform {
    x <- State.get;
    perform IO.print (intToString x)
  }
-- readAndPrint : {State Int, IO} Unit
```

## Built-in Effects

- **Pure** - No effects (default)
- **IO** - Input/output operations
- **State** - Mutable state
- **Error** - Exception handling
- **Async** - Asynchronous operations

## Effect Handlers (Limited)

Basic handler syntax is recognized:

```haskell
handle expr {
  IO.print s k -> -- Handle print operation
  Return x -> x   -- Handle final value
}
```

Note: Full handler evaluation is still under development.

## Best Practices

1. Keep effects minimal and localized
2. Separate pure logic from effectful operations
3. Use type signatures to document effects
4. Handle effects at the application boundary