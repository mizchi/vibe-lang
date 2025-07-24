# XS Language - New Features Documentation

This document describes the new features added to XS Language in December 2024.

## Table of Contents
1. [New Function Definition Syntax](#new-function-definition-syntax)
2. [Optional Parameters](#optional-parameters)
3. [Content-Addressed Code](#content-addressed-code)
4. [Type Inference Auto-Embedding](#type-inference-auto-embedding)

## New Function Definition Syntax

XS now supports a more explicit function definition syntax that makes type annotations clearer and more readable.

### Basic Syntax

```haskell
let functionName param1:Type1 param2:Type2 -> ReturnType = body
```

### Examples

```haskell
-- Simple function with type annotations
let add x:Int y:Int -> Int = x + y

-- Function with effects
let printInt x:Int -> <IO> Unit = perform IO.print (intToString x)

-- Recursive function
let factorial = rec f n:Int -> Int =
  if n == 0 { 1 } else { n * (f (n - 1)) }
```

### Benefits
- Clear parameter and return type annotations
- Better IDE support for type information
- More readable for AI code analysis

## Optional Parameters

Functions can now have optional parameters using the `?` syntax.

### Syntax

```haskell
let functionName required:Type optional?:Type? -> ReturnType = body
```

### Rules
1. Optional parameters must come after all required parameters
2. `Type?` is syntactic sugar for `Option<Type>`
3. Optional parameters can be omitted when calling the function

### Examples

```haskell
-- Function with optional parameter
let greet name:String title?:String? -> String =
  match title {
    None -> strConcat "Hello, " name
    Some t -> strConcat "Hello, " (strConcat t (strConcat " " name))
  }

-- Calling with and without optional parameter
greet "Alice" None              -- "Hello, Alice"
greet "Bob" (Some "Dr.")        -- "Hello, Dr. Bob"

-- Multiple optional parameters
let config port:Int host?:String? debug?:Bool? -> Config =
  { 
    port: port,
    host: match host { None -> "localhost", Some h -> h },
    debug: match debug { None -> false, Some d -> d }
  }

-- Partial application works correctly
let localConfig = config 8080   -- Type: String? -> Bool? -> Config
```

## Content-Addressed Code

XS implements a Unison-style content-addressed code storage system where every expression is identified by its content hash.

### Hash References

Use `#hash` syntax to reference previously defined expressions by their hash:

```haskell
-- In the shell:
xs> let double = fn x -> x * 2
double : Int -> Int
  [abc123de...]

xs> #abc123de 42  -- Apply the function by its hash
84
```

### Version-Specific Imports

Import specific versions of modules using hash syntax:

```haskell
import Math@1a2b3c4d        -- Import specific version
import List@5e6f7a8b as L   -- With alias
```

### Type Dependency Tracking

The system now tracks type dependencies in addition to function dependencies:

```haskell
type Point = { x: Int, y: Int }

-- This function depends on the Point type
let distance p:Point -> Float =
  sqrt (float (p.x * p.x + p.y * p.y))
```

When the `Point` type definition changes, all dependent functions are automatically identified.

### Benefits
1. **Immutable Code**: Once defined, code never changes
2. **Perfect Dependency Tracking**: Know exactly what depends on what
3. **Version Safety**: Reference exact versions you've tested
4. **Refactoring Support**: Safe renaming since code is identified by content

## Type Inference Auto-Embedding

XS automatically embeds inferred types into expressions when they are stored in the codebase.

### How It Works

When you define a function without explicit type annotations:

```haskell
-- You write:
let double = fn x -> x * 2

-- System stores:
let double : Int -> Int = fn x -> x * 2
```

### Viewing Embedded Types

Use the `view` command in the shell to see the embedded types:

```haskell
xs> let add = fn x y -> x + y
add : Int -> Int -> Int

xs> view add
let add : Int -> Int -> Int = fn x y -> x + y
  (inferred)
```

### Benefits
1. **Type Documentation**: Types are always available
2. **Better Error Messages**: Type information helps diagnose issues
3. **AI-Friendly**: Explicit types make code easier to analyze
4. **No Manual Annotation**: Get benefits of type annotations without writing them

## Integration Example

Here's how these features work together:

```haskell
-- Define a processing pipeline with optional configuration
let processData data:[Int] normalizer?:(Int -> Float)? threshold?:Float? -> [Float] =
  let normalize = match normalizer {
    None -> fn x -> float x
    Some f -> f
  } in
  let limit = match threshold {
    None -> 100.0
    Some t -> t
  } in
    map (fn x -> 
      let normalized = normalize x in
        if normalized > limit { limit } else { normalized }
    ) data

-- Store in codebase - types are embedded automatically
xs> add processData
Added processData : [Int] -> (Int -> Float)? -> Float? -> [Float]
  [def789ab...]

-- Import specific version in another module
import DataProcessing@def789ab

-- Create specialized version
let processIntegers = processData #def789ab  -- Partial application by hash
```

## Migration Guide

### From Old Lambda Syntax to New Function Syntax

```haskell
-- Old:
let add = fn x y -> x + y

-- New (with types):
let add x:Int y:Int -> Int = x + y

-- Both are valid, choose based on clarity needs
```

### Adding Optional Parameters

```haskell
-- Old (using Maybe):
let process = fn key flag ->
  match flag {
    None -> key
    Some f -> key + f
  }

-- New (with optional parameter):
let process key:Int flag?:Int? -> Int =
  match flag {
    None -> key
    Some f -> key + f
  }
```

## Best Practices

1. **Use explicit types for public APIs**: Makes interfaces clearer
2. **Let type inference work for internal functions**: Reduces boilerplate
3. **Reference stable code by hash**: Ensures reproducibility
4. **Put optional parameters last**: Required by the language, good for partial application
5. **Use namespace organization**: Helps manage large codebases

## Future Directions

These features lay the groundwork for:
- Distributed code sharing (exchange code by hash)
- Time-travel debugging (reference any historical version)
- Parallel development (no merge conflicts with content addressing)
- AI-assisted development (clear types and immutable references)