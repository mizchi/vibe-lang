# XS Language Module System

The XS language provides a module system for organizing code into reusable units.

## Defining Modules

Modules are defined using the `module` keyword:

```lisp
(module ModuleName
    (export identifier1 identifier2 ...)
    
    ; Module body - definitions
    (let identifier1 ...)
    (type TypeName ...)
    ...)
```

## Exporting from Modules

The `export` clause lists all identifiers (values and types) that should be publicly accessible:

```lisp
(module Math
    (export add sub PI)  ; Export these identifiers
    
    (let PI 3.14159)
    (let add (fn (x y) (+ x y)))
    (let sub (fn (x y) (- x y)))
    (let internal-helper (fn (x) (* x 2)))  ; Not exported, so private
)
```

## Importing from Modules

There are two ways to import from modules:

### 1. Selective Import

Import specific identifiers from a module:

```lisp
(import (Math add PI))
; Now 'add' and 'PI' are available in the current scope
(add 5 10)  ; => 15
```

### 2. Qualified Import

Import a module with a prefix:

```lisp
(import Math as M)
; Access module members with qualified names
(M.add 5 10)  ; => 15
(M.PI)        ; => 3.14159
```

## Type Definitions in Modules

Modules can export type definitions:

```lisp
(module DataStructures
    (export Stack push pop empty)
    
    ; Define and export a type
    (type Stack 
        (Empty)
        (Node value rest))
    
    ; Define operations on the type
    (let empty (Empty))
    
    (let push (fn (stack value)
        (Node value stack)))
    
    (let pop (fn (stack)
        (match stack
            ((Empty) (list))
            ((Node value rest) (list value rest))))))
```

## Module Scoping

Variables defined inside a module are private by default:

```lisp
(module Example
    (export public-fn)
    
    (let private-var 42)  ; Not accessible outside the module
    
    (let public-fn (fn ()
        private-var)))  ; Can access private-var internally
```

## Complete Example

```lisp
; math_utils.xs
(module MathUtils
    (export factorial fibonacci gcd)
    
    (rec factorial (n)
        (if (= n 0)
            1
            (* n (factorial (- n 1)))))
    
    (rec fibonacci (n)
        (if (< n 2)
            n
            (+ (fibonacci (- n 1))
               (fibonacci (- n 2)))))
    
    (rec gcd (a b)
        (if (= b 0)
            a
            (gcd b (% a b)))))

; main.xs
(import MathUtils as Math)

(print (Math.factorial 5))    ; => 120
(print (Math.fibonacci 10))   ; => 55
(print (Math.gcd 48 18))      ; => 6
```

## Current Limitations

- Module definitions must appear at the top level
- Circular dependencies between modules are not yet supported
- Module files are not yet automatically resolved from the filesystem
- Re-exporting from imported modules is not yet supported

## Future Enhancements

- Automatic module file resolution
- Nested modules
- Module signatures/interfaces
- Re-export functionality
- Module-level documentation