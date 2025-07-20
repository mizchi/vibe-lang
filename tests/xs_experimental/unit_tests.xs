; Unit tests using test framework style
; expect: true

; Helper function to check if value is an error
(let is-error (fn (value)
  (match value
    ((list "TEST_ERROR" msg) true)
    (_ false))) in

; Simple equality assertion for integers
(let assert-eq-int (fn (actual expected)
  (if (= actual expected)
      true
      (cons "TEST_ERROR" (str-concat 
              (str-concat "Expected: " (int-to-string expected))
              (str-concat ", but got: " (int-to-string actual)))))) in

; Simple equality assertion for strings
(let assert-eq-str (fn (actual expected)
  (if (str-eq actual expected)
      true
      (cons "TEST_ERROR" (str-concat 
              (str-concat "Expected: \"" (str-concat expected "\""))
              (str-concat ", but got: \"" (str-concat actual "\"")))))) in

; Basic assertion
(let assert (fn (expr)
  (if expr
      true
      (cons "TEST_ERROR" "Assertion failed"))) in

; Test runner
(let run-test (fn (name test-fn)
  (let result (test-fn) in
    (if (is-error result)
        (let _ (print (str-concat "✗ " (str-concat name (str-concat ": " (match result ((list "TEST_ERROR" msg) msg) (_ "")))))) in false)
        (let _ (print (str-concat "✓ " name)) in true)))) in

; Test 1: Basic arithmetic
(let test1 (run-test "basic arithmetic" (fn ()
  (let r1 (assert-eq-int (+ 2 2) 4) in
    (if (is-error r1) r1
        (let r2 (assert-eq-int (* 3 4) 12) in
          (if (is-error r2) r2
              (assert-eq-int (- 10 5) 5))))))) in

; Test 2: String operations
(let test2 (run-test "string operations" (fn ()
  (let r1 (assert-eq-str (str-concat "Hello, " "World!") "Hello, World!") in
    (if (is-error r1) r1
        (let r2 (assert-eq-int (string-length "hello") 5) in
          (if (is-error r2) r2
              (assert-eq-str (int-to-string 42) "42"))))))) in

; Test 3: Lambda expressions
(let test3 (run-test "lambda expressions" (fn ()
  (let r1 (assert-eq-int ((fn (x) x) 10) 10) in
    (if (is-error r1) r1
        (assert-eq-int ((fn (x y) (+ x y)) 3 4) 7))))) in

; Test 4: Conditionals
(let test4 (run-test "conditionals" (fn ()
  (let r1 (assert-eq-int (if true 1 2) 1) in
    (if (is-error r1) r1
        (assert-eq-int (if false 1 2) 2))))) in

; Test 5: Let bindings
(let test5 (run-test "let bindings" (fn ()
  (let x 10 in
    (let y (+ x 5) in
      (assert-eq-int y 15))))) in

; Test 6: List operations
(let test6 (run-test "list operations" (fn ()
  (let list1 (list 1 2 3) in
    (let list2 (cons 0 list1) in
      (match list2
        ((list 0 (list 1 (list 2 (list 3 (list))))) true)
        (_ (cons "TEST_ERROR" "List construction failed"))))))) in

; Test 7: Partial application
(let test7 (run-test "partial application" (fn ()
  (let add (fn (x y) (+ x y)) in
    (let add5 (add 5) in
      (assert-eq-int (add5 3) 8))))) in

; Test 8: Higher-order functions
(let test8 (run-test "higher-order functions" (fn ()
  (let apply-twice (fn (f x) (f (f x))) in
    (let inc (fn (x) (+ x 1)) in
      (assert-eq-int (apply-twice inc 5) 7))))) in

; Summary
(let passed (+ (if test1 1 0)
               (+ (if test2 1 0)
                  (+ (if test3 1 0)
                     (+ (if test4 1 0)
                        (+ (if test5 1 0)
                           (+ (if test6 1 0)
                              (+ (if test7 1 0)
                                 (if test8 1 0)))))))) in
  (let _ (print (str-concat "\nTotal: 8 tests, " (str-concat (int-to-string passed) " passed"))) in
    (= passed 8)))))))))))))))