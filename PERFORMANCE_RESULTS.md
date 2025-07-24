# Parser Performance Benchmark Results

## Test Environment
- Date: 2025-07-23
- Parser: parser (Haskell-style syntax with block scopes)
- Optimization: Release build

## Benchmark Results

### Simple Expression Parsing
```haskell
let x = 42
```
**Time**: ~146 ns

### Complex Expression Parsing (Recursive Function)
```haskell
let factorial = rec fact n ->
    if (eq n 0) {
        1
    } else {
        n * (fact (n - 1))
    }
let result = factorial 10
```
**Time**: ~593 ns

### Nested Block Parsing
```haskell
let outer = {
    let a = 10
    let b = {
        let x = 5
        let y = {
            let z = 2
            z + 3
        }
        x * y
    }
    a + b
}
```
**Time**: ~2.44 µs

### Pattern Matching Parsing
```haskell
let process = fn lst ->
    match lst {
        [] -> 0
        [x] -> x
        [x, y] -> x + y
        x :: xs -> x + (sum xs)
    }
```
**Time**: ~405 ns

### Pipeline Operations Parsing
```haskell
let result = [1, 2, 3, 4, 5]
    |> map (fn x -> x * 2)
    |> filter (fn x -> x > 5)
    |> foldLeft 0 (fn acc x -> acc + x)
```
**Time**: ~881 ns

## Analysis

The new parser (parser) demonstrates excellent performance:

1. **Simple expressions**: Sub-150ns parsing time
2. **Complex recursive functions**: Sub-600ns for multi-line function definitions
3. **Deeply nested blocks**: ~2.4µs even for 3-level nested blocks
4. **Pattern matching**: ~400ns for multi-case match expressions
5. **Pipeline operations**: Sub-900ns for chained operations

These results show that the Haskell-style syntax parser maintains high performance while providing more readable syntax compared to S-expressions.