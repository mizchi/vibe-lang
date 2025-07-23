; Test script for new shell features
; Run this in xs-shell to test namespace and redefinition warnings

; Test 1: Define a function
(let add (fn (x y) (+ x y)))

; Test 2: Redefine with same implementation (should show "unchanged")
(let add (fn (x y) (+ x y)))

; Test 3: Redefine with different implementation (should show "updated")
(let add (fn (a b) (+ a b)))

; Test 4: Test with Float arithmetic
(let celsiusToFahrenheit (fn (c: Float) (+ (* c 1.8) 32.0)))

; Test 5: Test modulo operator
(let isEven (fn (n: Int) (= (% n 2) 0)))

; Test expressions
(add 1 2)
(celsiusToFahrenheit 0.0)
(isEven 4)
(isEven 7)