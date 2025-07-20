# Advanced Features in XS

This tutorial covers XS's advanced features for building sophisticated programs.

## Custom Data Types

Define your own algebraic data types (ADTs):

```lisp
; Simple enumeration
(type Color
    Red
    Green 
    Blue)

; Type with data
(type Shape
    (Circle radius)
    (Rectangle width height)
    (Triangle base height))

; Recursive types
(type Tree
    (Leaf value)
    (Node left right))
```

## Pattern Matching on Custom Types

Use pattern matching to work with ADTs:

```lisp
(let area (fn (shape)
    (match shape
        ((Circle r) (* 3.14159 (* r r)))
        ((Rectangle w h) (* w h))
        ((Triangle b h) (/ (* b h) 2)))))

(area (Circle 5))           ; => 78.53975
(area (Rectangle 10 20))    ; => 200
```

## Advanced Pattern Matching

### Nested Patterns

```lisp
(type Person (Person name age))
(type Company (Company name employees))

(let get-employee-names (fn (company)
    (match company
        ((Company _ employees)
            (map (fn (person)
                (match person
                    ((Person name _) name)))
                employees)))))
```

### Pattern Guards (when implemented)

```lisp
(let classify-age (fn (person)
    (match person
        ((Person name age) 
            (if (< age 18)
                (concat name " is a minor")
                (concat name " is an adult"))))))
```

## Higher-Order Functions

Functions that operate on other functions:

```lisp
; Function composition
(let compose (fn (f g)
    (fn (x) (f (g x)))))

(let add1 (fn (x) (+ x 1)))
(let double (fn (x) (* x 2)))
(let add1-then-double (compose double add1))

(add1-then-double 5)  ; => 12

; Currying
(let curry2 (fn (f)
    (fn (x) (fn (y) (f x y)))))

(let add (fn (x y) (+ x y)))
(let curried-add (curry2 add))
(let add5 (curried-add 5))

(add5 10)  ; => 15
```

## Mutual Recursion

Define mutually recursive functions with `let-rec`:

```lisp
(let-rec even (n)
    (if (= n 0)
        true
        (odd (- n 1))))

(let-rec odd (n)
    (if (= n 0)
        false
        (even (- n 1))))

(even 10)  ; => true
(odd 10)   ; => false
```

## Advanced List Processing

### List Comprehensions (via map/filter)

```lisp
; Generate squares of even numbers
(let even-squares (fn (numbers)
    (map (fn (x) (* x x))
        (filter (fn (x) (= (% x 2) 0))
            numbers))))

(even-squares (list 1 2 3 4 5 6))  ; => (list 4 16 36)
```

### Lazy Evaluation Patterns

```lisp
; Generate infinite list (conceptually)
(rec take (n lst)
    (if (= n 0)
        (list)
        (match lst
            ((list) (list))
            ((list h t) (cons h (take (- n 1) t))))))

(rec range-from (start)
    (cons start (range-from (+ start 1))))

; In practice, you'd need lazy evaluation support
; This shows the pattern
```

## Error Handling Patterns

Using ADTs for error handling:

```lisp
(type Result
    (Ok value)
    (Error message))

(let safe-divide (fn (x y)
    (if (= y 0)
        (Error "Division by zero")
        (Ok (/ x y)))))

(let handle-result (fn (result)
    (match result
        ((Ok value) (print value))
        ((Error msg) (print (concat "Error: " msg))))))

(handle-result (safe-divide 10 2))   ; Prints: 5
(handle-result (safe-divide 10 0))   ; Prints: Error: Division by zero
```

## Advanced Type Patterns

### Phantom Types (conceptual)

```lisp
(type Distance (Meters value))
(type Time (Seconds value))
(type Speed (MetersPerSecond value))

(let calculate-speed (fn (distance time)
    (match (list distance time)
        ((list (Meters d) (Seconds t))
            (MetersPerSecond (/ d t))))))

; Type safety prevents mixing units
```

### Type Aliases (when implemented)

```lisp
(type-alias Point (list Int Int))
(type-alias Vector Point)
(type-alias Matrix (list (list Int)))
```

## Performance Considerations

### Tail Recursion

Write tail-recursive functions for better performance:

```lisp
; Non-tail-recursive (can stack overflow)
(rec sum (lst)
    (match lst
        ((list) 0)
        ((list h t) (+ h (sum t)))))

; Tail-recursive (accumulator pattern)
(rec sum-tail (lst acc)
    (match lst
        ((list) acc)
        ((list h t) (sum-tail t (+ acc h)))))

(let sum (fn (lst) (sum-tail lst 0)))
```

### Memoization Pattern

```lisp
; Manual memoization for expensive computations
(let make-memoized (fn (f)
    (let cache (list))  ; In real implementation, use a map
    (fn (x)
        ; Check cache first
        ; If not found, compute and store
        (f x))))  ; Simplified
```

## Working with Complex Data

### Tree Operations

```lisp
(type Tree
    (Leaf value)
    (Node left value right))

(rec tree-map (f tree)
    (match tree
        ((Leaf v) (Leaf (f v)))
        ((Node l v r) 
            (Node (tree-map f l) (f v) (tree-map f r)))))

(rec tree-fold (f init tree)
    (match tree
        ((Leaf v) (f init v))
        ((Node l v r)
            (let left-result (tree-fold f init l))
            (let center-result (f left-result v))
            (tree-fold f center-result r))))
```

### Graph Representation

```lisp
; Adjacency list representation
(type Graph (Graph nodes edges))
(type Node (Node id data))
(type Edge (Edge from to weight))

(let find-neighbors (fn (graph node-id)
    (match graph
        ((Graph nodes edges)
            (filter (fn (edge)
                (match edge
                    ((Edge from _ _) (= from node-id))))
                edges)))))
```

## Debugging Techniques

### Tracing Function Calls

```lisp
(let trace (fn (name f)
    (fn (x)
        (print (concat "Calling " (concat name (concat " with " (show x)))))
        (let result (f x))
        (print (concat name (concat " returned " (show result))))
        result))))

(let factorial-traced (trace "factorial" factorial))
```

### Assertions

```lisp
(let assert (fn (condition message)
    (if (not condition)
        (error message)
        true)))

(let divide (fn (x y)
    (assert (not (= y 0)) "Divisor must not be zero")
    (/ x y)))
```

## Best Practices for Advanced XS

1. **Type-Driven Development** - Define types first, implementation follows
2. **Small Functions** - Each function should do one thing well
3. **Immutability** - Never mutate data, create new versions
4. **Pattern Matching** - Prefer pattern matching over nested conditionals
5. **Higher-Order Functions** - Abstract common patterns

## Summary

Advanced XS features enable:
- **Type Safety** through custom ADTs
- **Expressiveness** with pattern matching
- **Modularity** with higher-order functions
- **Correctness** through immutability
- **Performance** with tail recursion

These features combine to make XS powerful for building reliable, maintainable software while remaining simple enough for AI analysis.