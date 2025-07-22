; XS Language Demo - Unified S-expression and Shell Syntax
; This file demonstrates both syntaxes coexisting in the same workspace

; Traditional S-expression definitions
(let double (fn (x) (* x 2)))
(let triple (fn (x) (* x 3)))
(let square (fn (x) (* x x)))

; Using functions with S-expression syntax
(let result1 (double 21))  ; => 42
(let result2 (triple 7))   ; => 21
(let result3 (square 5))   ; => 25

; List operations
(let numbers (list 1 2 3 4 5))
(let doubled (map double numbers))  ; => (list 2 4 6 8 10)

; Function composition
(let compose (fn (f g) (fn (x) (f (g x)))))
(let sixTimes (compose double triple))
(let result4 (sixTimes 7))  ; => 42

; REPL Shell Examples (these would be typed interactively):
;
; Shell syntax examples:
; xs> ls
; xs> search type:Int
; xs> ls | filter kind function
; xs> definitions | filter kind function | sort name
; xs> search type:Int | take 5
;
; Mixed usage:
; xs> (double 21)
; xs> double 21
; xs> ls | filter kind function | take 3
; xs> (map double (list 1 2 3))
;
; Mode switching:
; xs> :mode          ; Check current mode
; xs> :shell         ; Switch to shell-only mode
; xs> :sexpr         ; Switch to S-expression-only mode
; xs> :auto          ; Switch to auto-detect mode (default)
; xs> :mixed         ; Switch to mixed mode