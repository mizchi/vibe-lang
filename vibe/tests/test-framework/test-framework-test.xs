; Test the test framework itself
; This file tests the core functionality of xs/lib/test.xs

; Test the test framework itself without import
; We'll define the minimal functions we need to test

; Test basic assertions
(let testAssert
  (test "assert with true value" (fn ()
    (assert true))))

(let testAssertFailure
  (test "assert with false value should fail" (fn ()
    (let result (assert false) in
      (isError result)))))

; Test equality assertions
(let testAssertEqPass
  (test "assertEquals with equal values" (fn ()
    (assertEquals 42 42))))

(let testAssertEqFail
  (test "assertEquals with different values should fail" (fn ()
    (let result (assertEquals 42 43) in
      (isError result)))))

; Test inequality assertions
(let testAssertNeqPass
  (test "assertNotEquals with different values" (fn ()
    (assertNotEquals 42 43))))

; Test type assertions
(let testAssertInt
  (test "assertInt with integer" (fn ()
    (assertInt 42))))

(let testAssertString
  (test "assertString with string" (fn ()
    (assertString "hello"))))

(let testAssertList
  (test "assertList with list" (fn ()
    (assertList (list 1 2 3)))))

; Test equality function
(let testEqNumbers
  (test "eq with equal numbers" (fn ()
    (assert (eq 42 42)))))

(let testEqStrings
  (test "eq with equal strings" (fn ()
    (assert (eq "hello" "hello")))))

(let testEqLists
  (test "eq with equal lists" (fn ()
    (assert (eq (list 1 2 3) (list 1 2 3))))))

(let testEqDifferentTypes
  (test "eq with different types" (fn ()
    (assert (not (eq 42 "42"))))))

; Test helper functions
(let testToString
  (test "toString converts values to strings" (fn ()
    (let _ (assertEquals (toString 42) "42") in
    (let _ (assertEquals (toString true) "true") in
    (let _ (assertEquals (toString false) "false") in
    (assertEquals (toString "hello") "\"hello\"")))))))

(let testTypeName
  (test "typeName returns correct type names" (fn ()
    (let _ (assertEquals (typeName 42) "Int") in
    (let _ (assertEquals (typeName "hello") "String") in
    (let _ (assertEquals (typeName (list 1 2)) "List") in
    (assertEquals (typeName true) "Bool")))))))

; Run all tests
(runTests (list
  testAssert
  testAssertFailure
  testAssertEqPass
  testAssertEqFail
  testAssertNeqPass
  testAssertInt
  testAssertString
  testAssertList
  testEqNumbers
  testEqStrings
  testEqLists
  testEqDifferentTypes
  testToString
  testTypeName))