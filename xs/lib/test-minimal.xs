; Minimal test framework for XS language
; A simplified version that works with current XS implementation

; Basic assertion functions
(let assert (fn (expr)
  (if expr
      true
      (cons "ERROR" (cons "Assertion failed" (list))))))

(let assertEquals (fn (actual expected)
  (if (= actual expected)
      true
      (cons "ERROR" (cons "Values not equal" (list))))))

; Simple test runner
(let test (fn (name testFn)
  (let result (testFn) in
    (if (= result true)
        (let msg (strConcat "✓ " name) in (print msg))
        (let msg (strConcat "✗ " name) in (print msg))))))

; Run multiple tests
(let runTests (fn (tests)
  (let runAll (rec runAll (ts)
    (match ts
      ((list) true)
      ((list t ...rest) (let _ t in (runAll rest)))))
  in (runAll tests))))

; Export functions
(list assert assertEquals test runTests)