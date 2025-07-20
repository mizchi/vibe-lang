# Getting Started with XS Language

Welcome to XS, an AI-friendly functional programming language designed for fast static analysis and clear code understanding.

## Installation

First, ensure you have Rust installed on your system. Then clone and build XS:

```bash
git clone https://github.com/mizchi/xs-lang-proto2
cd xs-lang-proto2
cargo build --release
```

Add the binary to your PATH:
```bash
export PATH="$PATH:$(pwd)/target/release"
```

## Your First XS Program

Create a file named `hello.xs`:

```lisp
; This is a comment
(print "Hello, XS!")
```

Run it:
```bash
xsc run hello.xs
```

Output:
```
"Hello, XS!"
✓ Execution successful

Result: "Hello, XS!"
```

## Basic Syntax

XS uses S-expressions (parenthesized expressions) for all code:

```lisp
; Numbers
42          ; Integer
3.14159     ; Float

; Strings
"Hello"

; Booleans
true
false

; Lists
(list 1 2 3)

; Function calls - operator comes first
(+ 1 2)           ; => 3
(* 10 20)         ; => 200
(print "Hello")   ; => "Hello" (and prints to console)
```

## Variables and Functions

### Variables

Use `let` to bind values to names:

```lisp
(let x 10)
(let message "Hello, World!")
(let pi 3.14159)
```

### Functions

Define functions with `fn`:

```lisp
; A simple function
(let add (fn (x y) (+ x y)))

; Using the function
(add 5 3)  ; => 8

; Functions can be passed around
(let apply-twice (fn (f x) (f (f x))))
(let inc (fn (x) (+ x 1)))
(apply-twice inc 5)  ; => 7
```

## Local Bindings with let-in

Use `let-in` for local variable bindings:

```lisp
(let-in x 10
  (let-in y 20
    (+ x y)))  ; => 30

; Variables are scoped
(let-in x 5
  (* x x))     ; => 25
; x is not available here
```

## Conditionals

Use `if` for conditional expressions:

```lisp
(let abs (fn (x)
  (if (< x 0)
      (- 0 x)
      x)))

(abs -5)   ; => 5
(abs 5)    ; => 5
```

## Pattern Matching

XS supports pattern matching on lists and custom types:

```lisp
(let length (fn (lst)
  (match lst
    ((list) 0)                    ; Empty list
    ((list head tail) 
      (+ 1 (length tail))))))     ; Non-empty list

(length (list 1 2 3))  ; => 3
```

## Recursive Functions

Use `rec` for recursive function definitions:

```lisp
(rec factorial (n)
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(factorial 5)  ; => 120
```

## Type System

XS has a strong static type system with type inference. You rarely need to write types:

```lisp
; XS infers that add takes two Ints and returns an Int
(let add (fn (x y) (+ x y)))

; You can add type annotations if desired
(let add : (-> Int Int Int)
  (fn (x y) (+ x y)))
```

## Lists

Lists are a fundamental data structure:

```lisp
; Create lists
(list 1 2 3)
(list)  ; empty list

; List operations
(cons 0 (list 1 2 3))     ; => (list 0 1 2 3)

; Pattern matching on lists
(rec sum (lst)
  (match lst
    ((list) 0)
    ((list h t) (+ h (sum t)))))

(sum (list 1 2 3 4 5))  ; => 15
```

## Printing and Debugging

The `print` function outputs a value and returns it:

```lisp
(let x (print (+ 2 3)))  ; Prints: 5
; x is now 5

; Useful for debugging
(let result 
  (print (* 
    (print (+ 1 2))    ; Prints: 3
    (print (+ 3 4))))  ; Prints: 7
  )                    ; Prints: 21
```

## Running XS Programs

The XS compiler (`xsc`) provides several commands:

```bash
# Parse and check syntax
xsc parse program.xs

# Type check
xsc check program.xs

# Run the program
xsc run program.xs

# Run tests
xsc test
```

## Next Steps

- Learn about [Modules](02-modules.md) for organizing larger programs
- Explore [Advanced Features](03-advanced-features.md) like custom types and effects
- Read about [Best Practices](04-best-practices.md) for writing idiomatic XS code

## Complete Example

Here's a small program that demonstrates several features:

```lisp
; Fibonacci sequence calculator

(rec fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1))
         (fib (- n 2)))))

; Generate first 10 Fibonacci numbers
(rec fib-list (n acc)
  (if (= n 0)
      acc
      (fib-list (- n 1) (cons (fib (- n 1)) acc))))

(let result (fib-list 10 (list)))
(print "First 10 Fibonacci numbers:")
(print result)
```

Save this as `fibonacci.xs` and run with `xsc run fibonacci.xs`.