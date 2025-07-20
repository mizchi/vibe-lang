; Test framework for XS language
; Provides assertion functions and test organization

; Test result types
(type TestResult
  (Pass String)              ; test name
  (Fail String String)       ; test name, failure message
  (Error String String))     ; test name, error message

; Test report type
(type TestReport
  (TestReport 
    Int                      ; total tests
    Int                      ; passed
    Int                      ; failed
    (List TestResult)))      ; detailed results

; Error handling - these will be provided by the runtime
; For now, we use a special marker to indicate test failure
(let error (fn (msg) (cons "TEST_ERROR" msg)))
(let is-error (fn (value)
  (match value
    ((list "TEST_ERROR" _) true)
    (_ false))))
(let get-error-message (fn (value)
  (match value
    ((list "TEST_ERROR" msg) msg)
    (_ ""))))

; Basic assertion - checks if expression is true
(let assert (fn (expr)
  (if expr
      true
      (error "Assertion failed"))))

(let assert-with-message (fn (expr message)
  (if expr
      true
      (error (str-concat "Assertion failed: " message)))))

; Equality assertion
(let assert-eq (fn (actual expected)
  (if (eq actual expected)
      true
      (error (str-concat 
              (str-concat "Expected: " (to-string expected))
              (str-concat ", but got: " (to-string actual)))))))

(let assert-eq-with-message (fn (actual expected message)
  (if (eq actual expected)
      true
      (error (str-concat 
              (str-concat message ": Expected: ")
              (str-concat (to-string expected)
                           (str-concat ", but got: " (to-string actual))))))))

; Inequality assertion
(let assert-neq (fn (actual expected)
  (if (not (eq actual expected))
      true
      (error (str-concat "Expected values to be different, but both were: " 
                          (to-string actual))))))

; Type assertions
(let assert-int (fn (value)
  (match value
    ((Int _) true)
    (_ (error (str-concat "Expected Int, but got: " (type-name value)))))))

(let assert-string (fn (value)
  (match value
    ((String _) true)
    (_ (error (str-concat "Expected String, but got: " (type-name value)))))))

(let assert-list (fn (value)
  (match value
    ((List _) true)
    (_ (error (str-concat "Expected List, but got: " (type-name value)))))))

; Test execution function
(let test (fn (name test-fn)
  (let result (test-fn) in
    (if (is-error result)
        (Fail name (get-error-message result))
        (Pass name)))))

; Test suite definition
(let test-suite (fn (suite-name tests)
  (let suite-results (map (fn (t) t) tests) in
    (TestReport 
      (length suite-results)
      (count-passed suite-results)
      (count-failed suite-results)
      suite-results))))

; Helper functions for equality comparison
(rec eq (a b)
  (match (list a b)
    ; Numbers
    ((list (Int x) (Int y)) (= x y))
    ((list (Float x) (Float y)) (Float.eq x y))
    ; Booleans
    ((list (Bool x) (Bool y)) (Bool.eq x y))
    ; Strings
    ((list (String x) (String y)) (str-eq x y))
    ; Lists
    ((list (List xs) (List ys)) (list-eq xs ys))
    ; Different types are not equal
    (_ false)))

(rec list-eq (xs ys)
  (match (list xs ys)
    ((list (list) (list)) true)
    ((list (list) _) false)
    ((list _ (list)) false)
    ((list (list x xs-rest) (list y ys-rest))
      (if (eq x y)
          (list-eq xs-rest ys-rest)
          false))))

; Convert value to string for error messages
(rec to-string (value)
  (match value
    ((Int n) (int-to-string n))
    ((Float f) "<float>")  ; Float.toString not implemented yet
    ((Bool b) (if b "true" "false"))
    ((String s) (str-concat "\"" (str-concat s "\"")))
    ((List xs) (str-concat "[" (str-concat (join-strings (map to-string xs) ", ") "]")))
    (_ "<unknown>")))

; Get type name for error messages
(let type-name (fn (value)
  (match value
    ((Int _) "Int")
    ((Float _) "Float")
    ((Bool _) "Bool")
    ((String _) "String")
    ((List _) "List")
    (_ "Unknown"))))

; Helper to join strings with separator
(rec join-strings (strings sep)
  (match strings
    ((list) "")
    ((list s) s)
    ((list s rest) (str-concat s (str-concat sep (join-strings rest sep))))))

; Count passed tests
(rec count-passed (results)
  (match results
    ((list) 0)
    ((list (Pass _) rest) (+ 1 (count-passed rest)))
    ((list _ rest) (count-passed rest))))

; Count failed tests
(rec count-failed (results)
  (match results
    ((list) 0)
    ((list (Fail _ _) rest) (+ 1 (count-failed rest)))
    ((list (Error _ _) rest) (+ 1 (count-failed rest)))
    ((list _ rest) (count-failed rest))))

; Format test result for display
(let format-result (fn (result)
  (match result
    ((Pass name) (str-concat "✓ " name))
    ((Fail name msg) (str-concat "✗ " (str-concat name (str-concat "\n  " msg))))
    ((Error name msg) (str-concat "✗ " (str-concat name (str-concat "\n  Error: " msg)))))))

; Run a list of tests and generate report
(let run-tests (fn (tests)
  (let results (map (fn (t) t) tests) in
    (let report (TestReport 
                  (length results)
                  (count-passed results)
                  (count-failed results)
                  results) in
      (print-report report)))))

; Print test report
(let print-report (fn (report)
  (match report
    ((TestReport total passed failed results)
      (let _ (print "\nTest Results:") in
      (let _ (print "=============") in
      (let _ (map (fn (r) (print (format-result r))) results) in
      (let _ (print "\nSummary:") in
      (let _ (print (str-concat "  Total: " (int-to-string total))) in
      (let _ (print (str-concat "  Passed: " (int-to-string passed))) in
      (let _ (print (str-concat "  Failed: " (int-to-string failed))) in
      (if (= failed 0)
          (print "\nAll tests passed! ✨")
          (print "\nSome tests failed! ❌")))))))))))))

; Helper functions that are missing from builtins
(let not (fn (b) (if b false true)))
(let Bool.eq (fn (a b) (if a b (not b))))
(let Float.eq (fn (a b) true))  ; Placeholder
(rec length (lst)
  (match lst
    ((list) 0)
    ((list _ rest) (+ 1 (length rest)))))
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h rest) (cons (f h) (map f rest)))))