; Simple test to verify test framework functionality

; Define a simple assert function
(let assert (fn (expr)
  (if expr
      true
      (cons "TEST_ERROR" (cons "Assertion failed" (list))))))

; Test if assert works
(let test1 (assert (= 1 1)) in
(let test2 (assert (= 1 2)) in

; Print results
(let x (print "Test 1 (should pass):") in
(let y (print test1) in
(let z (print "Test 2 (should fail):") in
(print test2))))))