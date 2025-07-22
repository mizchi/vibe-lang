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
(let isError (fn (value)
  (match value
    ((list "TEST_ERROR" _) true)
    (_ false))))
(let getErrorMessage (fn (value)
  (match value
    ((list "TEST_ERROR" msg) msg)
    (_ ""))))

; Basic assertion - checks if expression is true
(let assert (fn (expr)
  (if expr
      true
      (error "Assertion failed"))))

(let assertWithMessage (fn (expr message)
  (if expr
      true
      (error (strConcat "Assertion failed: " message)))))

; Equality assertion
(let assertEquals (fn (actual expected)
  (if (eq actual expected)
      true
      (error (strConcat 
              (strConcat "Expected: " (toString expected))
              (strConcat ", but got: " (toString actual)))))))

(let assertEqualsWithMessage (fn (actual expected message)
  (if (eq actual expected)
      true
      (error (strConcat 
              (strConcat message ": Expected: ")
              (strConcat (toString expected)
                           (strConcat ", but got: " (toString actual))))))))

; Inequality assertion
(let assertNotEquals (fn (actual expected)
  (if (not (eq actual expected))
      true
      (error (strConcat "Expected values to be different, but both were: " 
                          (toString actual))))))

; Type assertions
(let assertInt (fn (value)
  (match value
    ((Int _) true)
    (_ (error (strConcat "Expected Int, but got: " (typeName value)))))))

(let assertString (fn (value)
  (match value
    ((String _) true)
    (_ (error (strConcat "Expected String, but got: " (typeName value)))))))

(let assertList (fn (value)
  (match value
    ((List _) true)
    (_ (error (strConcat "Expected List, but got: " (typeName value)))))))

; Test execution function
(let test (fn (name testFn)
  (let result (testFn) in
    (if (isError result)
        (Fail name (getErrorMessage result))
        (Pass name)))))

; Test suite definition
(let testSuite (fn (suiteName tests)
  (let suiteResults (map (fn (t) t) tests) in
    (TestReport 
      (length suiteResults)
      (countPassed suiteResults)
      (countFailed suiteResults)
      suiteResults))))

; Helper functions for equality comparison
(rec eq (a b)
  (match (list a b)
    ; Numbers
    ((list (Int x) (Int y)) (= x y))
    ((list (Float x) (Float y)) (Float.eq x y))
    ; Booleans
    ((list (Bool x) (Bool y)) (Bool.eq x y))
    ; Strings
    ((list (String x) (String y)) (strEq x y))
    ; Lists
    ((list (List xs) (List ys)) (listEq xs ys))
    ; Different types are not equal
    (_ false)))

(rec listEq (xs ys)
  (match (list xs ys)
    ((list (list) (list)) true)
    ((list (list) _) false)
    ((list _ (list)) false)
    ((list (list x xsRest) (list y ysRest))
      (if (eq x y)
          (listEq xsRest ysRest)
          false))))

; Convert value to string for error messages
(rec toString (value)
  (match value
    ((Int n) (intToString n))
    ((Float f) "<float>")  ; Float.toString not implemented yet
    ((Bool b) (if b "true" "false"))
    ((String s) (strConcat "\"" (strConcat s "\"")))
    ((List xs) (strConcat "[" (strConcat (joinStrings (map toString xs) ", ") "]")))
    (_ "<unknown>")))

; Get type name for error messages
(let typeName (fn (value)
  (match value
    ((Int _) "Int")
    ((Float _) "Float")
    ((Bool _) "Bool")
    ((String _) "String")
    ((List _) "List")
    (_ "Unknown"))))

; Helper to join strings with separator
(rec joinStrings (strings sep)
  (match strings
    ((list) "")
    ((list s) s)
    ((list s rest) (strConcat s (strConcat sep (joinStrings rest sep))))))

; Count passed tests
(rec countPassed (results)
  (match results
    ((list) 0)
    ((list (Pass _) rest) (+ 1 (countPassed rest)))
    ((list _ rest) (countPassed rest))))

; Count failed tests
(rec countFailed (results)
  (match results
    ((list) 0)
    ((list (Fail _ _) rest) (+ 1 (countFailed rest)))
    ((list (Error _ _) rest) (+ 1 (countFailed rest)))
    ((list _ rest) (countFailed rest))))

; Format test result for display
(let formatResult (fn (result)
  (match result
    ((Pass name) (strConcat "✓ " name))
    ((Fail name msg) (strConcat "✗ " (strConcat name (strConcat "\n  " msg))))
    ((Error name msg) (strConcat "✗ " (strConcat name (strConcat "\n  Error: " msg)))))))

; Run a list of tests and generate report
(let runTests (fn (tests)
  (let results (map (fn (t) t) tests) in
    (let report (TestReport 
                  (length results)
                  (countPassed results)
                  (countFailed results)
                  results) in
      (printReport report)))))

; Print test report
(let printReport (fn (report)
  (match report
    ((TestReport total passed failed results)
      (let _ (print "\nTest Results:") in
      (let _ (print "=============") in
      (let _ (map (fn (r) (print (formatResult r))) results) in
      (let _ (print "\nSummary:") in
      (let _ (print (strConcat "  Total: " (intToString total))) in
      (let _ (print (strConcat "  Passed: " (intToString passed))) in
      (let _ (print (strConcat "  Failed: " (intToString failed))) in
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