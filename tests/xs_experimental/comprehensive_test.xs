; Comprehensive test suite using test framework
; expect: all tests pass

(import test)

(test-suite "Comprehensive Tests"
  (list
    ; Arithmetic operations
    (test "addition" (assert-eq (+ 2 2) 4))
    (test "subtraction" (assert-eq (- 10 5) 5))
    (test "multiplication" (assert-eq (* 3 4) 12))
    (test "division" (assert-eq (/ 20 4) 5))
    (test "nested arithmetic" (assert-eq (+ (* 2 3) (- 10 5)) 11))
    
    ; Comparison operations
    (test "equality" (assert (= 5 5)))
    (test "inequality" (assert (not (= 5 6))))
    (test "less than" (assert (< 3 5)))
    (test "greater than" (assert (> 5 3)))
    (test "less than or equal" (assert (<= 5 5)))
    (test "greater than or equal" (assert (>= 5 5)))
    
    ; String operations
    (test "string concat" (assert-eq-str (str-concat "Hello, " "World!") "Hello, World!"))
    (test "string length" (assert-eq (string-length "hello") 5))
    (test "int to string" (assert-eq-str (int-to-string 42) "42"))
    (test "string to int" (assert-eq (string-to-int "123") 123))
    
    ; Boolean operations
    (test "and true true" (assert (and true true)))
    (test "and true false" (assert (not (and true false))))
    (test "or true false" (assert (or true false)))
    (test "or false false" (assert (not (or false false))))
    (test "not true" (assert (not true) false))
    (test "not false" (assert (not false)))
    
    ; Lambda expressions
    (test "identity lambda" (assert-eq ((fn (x) x) 10) 10))
    (test "addition lambda" (assert-eq ((fn (x y) (+ x y)) 3 4) 7))
    (test "nested lambda" 
      (let f (fn (x) (fn (y) (+ x y))) in
        (assert-eq ((f 5) 3) 8)))
    
    ; Conditional expressions
    (test "if true branch" (assert-eq (if true 1 2) 1))
    (test "if false branch" (assert-eq (if false 1 2) 2))
    (test "nested if" 
      (assert-eq (if (> 5 3) (if true "yes" "no") "maybe") "yes"))
    
    ; Let bindings
    (test "simple let" 
      (let x 10 in (assert-eq x 10)))
    (test "nested let" 
      (let x 10 in (let y (+ x 5) in (assert-eq y 15))))
    (test "shadowing let" 
      (let x 10 in (let x 20 in (assert-eq x 20))))
    
    ; List operations
    (test "empty list" 
      (match (list)
        ((list) (pass))
        (_ (fail "Empty list mismatch"))))
    (test "single element list" 
      (match (list 1)
        ((list 1 (list)) (pass))
        (_ (fail "Single element list mismatch"))))
    (test "multi element list" 
      (match (list 1 2 3)
        ((list 1 (list 2 (list 3 (list)))) (pass))
        (_ (fail "Multi element list mismatch"))))
    (test "cons operation" 
      (match (cons 0 (list 1 2))
        ((list 0 (list 1 (list 2 (list)))) (pass))
        (_ (fail "Cons operation mismatch"))))
    
    ; Pattern matching
    (test "match number" 
      (assert-eq (match 5
                   (0 "zero")
                   (5 "five")
                   (_ "other")) "five"))
    (test "match list pattern" 
      (let sum-list (fn (lst)
                      (match lst
                        ((list) 0)
                        ((list h rest) (+ h (sum-list rest))))) in
        (assert-eq (sum-list (list 1 2 3 4 5)) 15)))
    
    ; Higher-order functions
    (test "map function" 
      (let map (fn (f lst)
                 (match lst
                   ((list) (list))
                   ((list h rest) (cons (f h) (map f rest))))) in
        (let double (fn (x) (* x 2)) in
          (match (map double (list 1 2 3))
            ((list 2 (list 4 (list 6 (list)))) (pass))
            (_ (fail "Map function mismatch"))))))
    
    (test "filter function" 
      (let filter (fn (pred lst)
                    (match lst
                      ((list) (list))
                      ((list h rest) 
                        (if (pred h)
                            (cons h (filter pred rest))
                            (filter pred rest))))) in
        (let is-even (fn (x) (= (% x 2) 0)) in
          (match (filter is-even (list 1 2 3 4 5))
            ((list 2 (list 4 (list))) (pass))
            (_ (fail "Filter function mismatch"))))))
    
    ; Partial application
    (test "partial application" 
      (let add (fn (x y) (+ x y)) in
        (let add5 (add 5) in
          (assert-eq (add5 3) 8))))
    
    ; Recursion
    (test "factorial" 
      (let factorial (rec fact (n)
                       (if (= n 0)
                           1
                           (* n (fact (- n 1))))) in
        (assert-eq (factorial 5) 120)))
    
    ; Complex expression
    (test "complex nested expression" 
      (let x 10 in
        (let f (fn (a) (+ a 1)) in
          (let g (fn (b) (* b 2)) in
            (assert-eq (g (f x)) 22)))))))