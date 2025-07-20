; Comprehensive test suite using the test framework
; expect: true

; Include test framework functions
(let-rec assert-eq (actual expected)
  (if (= actual expected)
      true
      (error (str-concat 
              (str-concat "Expected: " (int-to-string expected))
              (str-concat ", but got: " (int-to-string actual))))) in

(let-rec assert-eq-str (actual expected)
  (if (str-eq actual expected)
      true
      (error (str-concat 
              (str-concat "Expected: \"" (str-concat expected "\""))
              (str-concat ", but got: \"" (str-concat actual "\""))))) in

(let assert (expr)
  (if expr
      true
      (error "Assertion failed")) in

(let-rec run-test (name test-fn)
  (let result (test-fn) in
    (if (match result
          ((list "TEST_ERROR" _) true)
          (_ false))
        (let _ (print (str-concat "FAIL: " (str-concat name (str-concat " - " (match result ((list "TEST_ERROR" msg) msg) (_ "")))))) in false)
        (let _ (print (str-concat "PASS: " name)) in true))) in

; Test 1: Basic literals and arithmetic
(let test1 (run-test "basic literals" (fn ()
  (let _ (assert-eq 42 42) in
  (let _ (assert-eq (+ 2 2) 4) in
  (let _ (assert-eq (- 10 5) 5) in
  (let _ (assert-eq (* 3 4) 12) in
  (let _ (assert-eq (/ 20 4) 5) in
  true))))))) in

; Test 2: Lambda expressions
(let test2 (run-test "lambda expressions" (fn ()
  (let _ (assert-eq ((fn (x) x) 10) 10) in
  (let _ (assert-eq ((fn (x y) (+ x y)) 3 4) 7) in
  (let inc (fn (x) (+ x 1)) in
    (assert-eq (inc 5) 6))))) in

; Test 3: String operations
(let test3 (run-test "string operations" (fn ()
  (let _ (assert-eq-str (str-concat "Hello, " "World!") "Hello, World!") in
  (let _ (assert-eq (string-length "hello") 5) in
  (let _ (assert-eq-str (int-to-string 42) "42") in
  (let _ (assert-eq (string-to-int "123") 123) in
  true)))))) in

; Test 4: List operations
(let test4 (run-test "list operations" (fn ()
  (let-rec length (lst)
    (match lst
      ((list) 0)
      ((list h rest) (+ 1 (length rest)))) in
    (let _ (assert-eq (length (list 1 2 3)) 3) in
    (let _ (assert-eq (length (list)) 0) in
    (let _ (assert-eq (length (cons 1 (list 2 3))) 3) in
    true)))))) in

; Test 5: Conditional expressions
(let test5 (run-test "conditional expressions" (fn ()
  (let _ (assert-eq (if true 1 2) 1) in
  (let _ (assert-eq (if false 1 2) 2) in
  (let _ (assert-eq (if (> 5 3) "yes" "no") "yes") in
  (let _ (assert-eq (if (< 5 3) "yes" "no") "no") in
  true)))))) in

; Test 6: Let bindings
(let test6 (run-test "let bindings" (fn ()
  (let x 10 in
    (let _ (assert-eq x 10) in
    (let y (+ x 5) in
      (assert-eq y 15)))))) in

; Test 7: Recursion
(let test7 (run-test "recursion" (fn ()
  (let-rec factorial (n)
    (if (= n 0)
        1
        (* n (factorial (- n 1)))) in
    (let _ (assert-eq (factorial 0) 1) in
    (let _ (assert-eq (factorial 1) 1) in
    (let _ (assert-eq (factorial 5) 120) in
    true)))))) in

; Test 8: Pattern matching
(let test8 (run-test "pattern matching" (fn ()
  (let-rec sum-list (lst)
    (match lst
      ((list) 0)
      ((list h rest) (+ h (sum-list rest)))) in
    (let _ (assert-eq (sum-list (list 1 2 3 4 5)) 15) in
    (let _ (assert-eq (sum-list (list)) 0) in
    true))))) in

; Test 9: Higher-order functions
(let test9 (run-test "higher-order functions" (fn ()
  (let-rec map (f lst)
    (match lst
      ((list) (list))
      ((list h rest) (cons (f h) (map f rest)))) in
    (let double (fn (x) (* x 2)) in
      (let result (map double (list 1 2 3)) in
        (match result
          ((list 2 (list 4 (list 6 (list)))) true)
          (_ false))))))) in

; Test 10: Partial application
(let test10 (run-test "partial application" (fn ()
  (let add (fn (x y) (+ x y)) in
    (let add5 (add 5) in
      (let _ (assert-eq (add5 3) 8) in
      (let _ (assert-eq (add5 10) 15) in
      true)))))) in

; Combine all test results
(if test1
    (if test2
        (if test3
            (if test4
                (if test5
                    (if test6
                        (if test7
                            (if test8
                                (if test9
                                    test10
                                    false)
                                false)
                            false)
                        false)
                    false)
                false)
            false)
        false)
    false)))))))))))))))))