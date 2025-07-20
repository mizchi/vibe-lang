# Working with Modules in XS

Modules help organize code into reusable components. This tutorial covers how to create and use modules in XS.

## Creating Your First Module

Let's create a simple math utilities module:

```lisp
(module MathUtils
    (export square cube pow)
    
    (let square (fn (x) (* x x)))
    
    (let cube (fn (x) (* x x x)))
    
    (rec pow (base exp)
        (if (= exp 0)
            1
            (* base (pow base (- exp 1))))))
```

## Module Structure

A module consists of:
1. **Module name** - Identifies the module
2. **Export list** - Public interface
3. **Definitions** - Implementation details

```lisp
(module ModuleName
    (export public1 public2)  ; What's visible outside
    
    ; Private definitions (not exported)
    (let private-helper ...)
    
    ; Public definitions (exported)
    (let public1 ...)
    (let public2 ...))
```

## Importing from Modules

### Method 1: Selective Import

Import specific items from a module:

```lisp
(import (MathUtils square pow))

; Now use directly
(square 5)      ; => 25
(pow 2 8)       ; => 256
```

### Method 2: Qualified Import

Import with a namespace prefix:

```lisp
(import MathUtils as Math)

; Use with qualification
(Math.square 5)     ; => 25
(Math.cube 3)       ; => 27
(Math.pow 2 8)      ; => 256
```

## A Practical Example: List Utilities

Create a module for list operations:

```lisp
(module ListOps
    (export map filter fold-left fold-right reverse)
    
    ; Map function over list
    (rec map (f lst)
        (match lst
            ((list) (list))
            ((list h t) (cons (f h) (map f t)))))
    
    ; Filter list by predicate
    (rec filter (pred lst)
        (match lst
            ((list) (list))
            ((list h t)
                (if (pred h)
                    (cons h (filter pred t))
                    (filter pred t)))))
    
    ; Left fold
    (rec fold-left (f init lst)
        (match lst
            ((list) init)
            ((list h t) (fold-left f (f init h) t))))
    
    ; Right fold  
    (rec fold-right (f init lst)
        (match lst
            ((list) init)
            ((list h t) (f h (fold-right f init t)))))
    
    ; Reverse a list
    (let reverse (fn (lst)
        (fold-left (fn (acc x) (cons x acc)) (list) lst))))
```

Using the module:

```lisp
(import ListOps as L)

(let numbers (list 1 2 3 4 5))

; Double all numbers
(L.map (fn (x) (* x 2)) numbers)  ; => (list 2 4 6 8 10)

; Keep only even numbers
(L.filter (fn (x) (= (% x 2) 0)) numbers)  ; => (list 2 4)

; Sum all numbers
(L.fold-left + 0 numbers)  ; => 15

; Reverse the list
(L.reverse numbers)  ; => (list 5 4 3 2 1)
```

## Modules with Types

Modules can export custom types:

```lisp
(module Stack
    (export Stack empty push pop top is-empty)
    
    ; Define the Stack type
    (type Stack
        (Empty)
        (Node value rest))
    
    ; Create empty stack
    (let empty (Empty))
    
    ; Push value onto stack
    (let push (fn (stack value)
        (Node value stack)))
    
    ; Pop from stack (returns (value, rest-of-stack))
    (let pop (fn (stack)
        (match stack
            ((Empty) (list))
            ((Node value rest) (list value rest)))))
    
    ; Get top value
    (let top (fn (stack)
        (match stack
            ((Empty) 0)  ; or error
            ((Node value _) value))))
    
    ; Check if empty
    (let is-empty (fn (stack)
        (match stack
            ((Empty) true)
            ((Node _ _) false)))))
```

Using the Stack module:

```lisp
(import Stack as S)

(let s1 S.empty)
(let s2 (S.push s1 10))
(let s3 (S.push s2 20))
(let s4 (S.push s3 30))

(print (S.top s4))        ; => 30
(print (S.is-empty s1))   ; => true
(print (S.is-empty s4))   ; => false

; Pop and get result
(match (S.pop s4)
    ((list value rest)
        (print value)      ; => 30
        (print (S.top rest))))  ; => 20
```

## Module Organization Best Practices

### 1. Single Responsibility

Each module should have one clear purpose:

```lisp
; Good: Focused modules
(module StringUtils ...)
(module FileIO ...)
(module JsonParser ...)

; Avoid: Kitchen sink modules
(module Utilities ...)  ; Too vague
```

### 2. Clear Interfaces

Export only what's necessary:

```lisp
(module Parser
    (export parse)  ; Only export the main function
    
    ; Keep helpers private
    (let tokenize ...)
    (let build-ast ...)
    (let validate ...))
```

### 3. Documentation

Document your modules:

```lisp
(module Statistics
    ; Statistical functions for numeric lists
    (export mean median mode std-dev)
    
    ; Calculate arithmetic mean
    (let mean (fn (numbers) ...))
    
    ; Find middle value
    (let median (fn (numbers) ...)))
```

## Advanced Module Patterns

### Factory Functions

Create configured instances:

```lisp
(module Logger
    (export create-logger)
    
    (let create-logger (fn (prefix)
        (fn (message)
            (print (concat prefix message))))))

(import (Logger create-logger))
(let info-log (create-logger "[INFO] "))
(let error-log (create-logger "[ERROR] "))

(info-log "Application started")    ; => "[INFO] Application started"
(error-log "Connection failed")     ; => "[ERROR] Connection failed"
```

### Module Composition

Build larger modules from smaller ones:

```lisp
(module BasicMath
    (export add sub mul div))

(module AdvancedMath
    (export sin cos tan log))

(module Math
    ; Re-export from other modules
    (export add sub mul div sin cos tan log)
    
    (import (BasicMath add sub mul div))
    (import (AdvancedMath sin cos tan log)))
```

## Common Pitfalls

1. **Circular Dependencies** - Currently not supported
2. **Name Conflicts** - Use qualified imports to avoid
3. **Over-exporting** - Keep interfaces minimal

## Summary

Modules in XS provide:
- **Encapsulation** - Hide implementation details
- **Reusability** - Share code between projects
- **Organization** - Structure large programs
- **Type Safety** - Export types with their operations

Next: Learn about [Advanced Features](03-advanced-features.md) including pattern matching, custom types, and more.