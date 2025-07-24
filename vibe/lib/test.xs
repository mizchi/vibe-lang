-- Test framework for XS language
-- Provides assertion functions and test organization

-- Test result types
type TestResult =
  | Pass String              -- test name
  | Fail String String       -- test name, failure message
  | Error String String      -- test name, error message

-- Test report type
type TestReport =
  | TestReport 
      Int                      -- total tests
      Int                      -- passed
      Int                      -- failed
      [TestResult]             -- detailed results

-- Error handling - these will be provided by the runtime
-- For now, we use a special marker to indicate test failure
let error = \msg -> cons "TEST_ERROR" msg

let isError = \value ->
  case value of {
    "TEST_ERROR" :: _ -> true;
    _ -> false
  }

let getErrorMessage = \value ->
  case value of {
    "TEST_ERROR" :: msg :: _ -> msg;
    _ -> ""
  }

-- Basic assertion - checks if expression is true
let assert = \expr ->
  if expr {
    true
  } else {
    error "Assertion failed"
  }

let assertWithMessage = \expr message ->
  if expr {
    true
  } else {
    error (String.concat "Assertion failed: " message)
  }

-- Equality assertion
let assertEquals = \actual expected ->
  if eq actual expected {
    true
  } else {
    error (String.concat 
            (String.concat "Expected: " (toString expected))
            (String.concat ", but got: " (toString actual)))
  }

let assertEqualsWithMessage = \actual expected message ->
  if eq actual expected {
    true
  } else {
    error (String.concat 
            (String.concat message ": Expected: ")
            (String.concat (toString expected)
                         (String.concat ", but got: " (toString actual))))
  }

-- Inequality assertion
let assertNotEquals = \actual expected ->
  if not (eq actual expected) {
    true
  } else {
    error (String.concat "Expected values to be different, but both were: " 
                        (toString actual))
  }

-- Type assertions
let assertInt = \value ->
  case value of {
    Int _ -> true;
    _ -> error (String.concat "Expected Int, but got: " (typeName value))
  }

let assertString = \value ->
  case value of {
    String _ -> true;
    _ -> error (String.concat "Expected String, but got: " (typeName value))
  }

let assertList = \value ->
  case value of {
    List _ -> true;
    _ -> error (String.concat "Expected List, but got: " (typeName value))
  }

-- Test execution function
let test = \name testFn ->
  let result = testFn in
    if isError result {
      Fail name (getErrorMessage result)
    } else {
      Pass name
    }

-- Test suite definition
let testSuite = \suiteName tests ->
  let suiteResults = map (\t -> t) tests in
    TestReport 
      (length suiteResults)
      (countPassed suiteResults)
      (countFailed suiteResults)
      suiteResults

-- Helper functions for equality comparison
rec eq a b =
  case [a, b] of {
    -- Numbers
    [Int x, Int y] -> x == y;
    [Float x, Float y] -> Float.eq x y;
    -- Booleans
    [Bool x, Bool y] -> Bool.eq x y;
    -- Strings
    [String x, String y] -> String.eq x y;
    -- Lists
    [List xs, List ys] -> listEq xs ys;
    -- Different types are not equal
    _ -> false
  }

rec listEq xs ys =
  case [xs, ys] of {
    [[], []] -> true;
    [[], _] -> false;
    [_, []] -> false;
    [x :: xsRest, y :: ysRest] ->
      if eq x y {
        listEq xsRest ysRest
      } else {
        false
      }
  }

-- Convert value to string for error messages
rec toString value =
  case value of {
    Int n -> Int.toString n;
    Float f -> "<float>";  -- Float.toString not implemented yet
    Bool b -> if b { "true" } else { "false" };
    String s -> String.concat "\"" (String.concat s "\"");
    List xs -> String.concat "[" (String.concat (joinStrings (map toString xs) ", ") "]");
    _ -> "<unknown>"
  }

-- Get type name for error messages
let typeName = \value ->
  case value of {
    Int _ -> "Int";
    Float _ -> "Float";
    Bool _ -> "Bool";
    String _ -> "String";
    List _ -> "List";
    _ -> "Unknown"
  }

-- Helper to join strings with separator
rec joinStrings strings sep =
  case strings of {
    [] -> "";
    [s] -> s;
    s :: rest -> String.concat s (String.concat sep (joinStrings rest sep))
  }

-- Count passed tests
rec countPassed results =
  case results of {
    [] -> 0;
    Pass _ :: rest -> 1 + countPassed rest;
    _ :: rest -> countPassed rest
  }

-- Count failed tests
rec countFailed results =
  case results of {
    [] -> 0;
    Fail _ _ :: rest -> 1 + countFailed rest;
    Error _ _ :: rest -> 1 + countFailed rest;
    _ :: rest -> countFailed rest
  }

-- Format test result for display
let formatResult = \result ->
  case result of {
    Pass name -> String.concat "✓ " name;
    Fail name msg -> String.concat "✗ " (String.concat name (String.concat "\n  " msg));
    Error name msg -> String.concat "✗ " (String.concat name (String.concat "\n  Error: " msg))
  }

-- Run a list of tests and generate report
let runTests = \tests ->
  let results = map (\t -> t) tests in
    let report = TestReport 
                  (length results)
                  (countPassed results)
                  (countFailed results)
                  results in
      printReport report

-- Print test report
let printReport = \report ->
  case report of {
    TestReport total passed failed results ->
      let _ = IO.print "\nTest Results:" in
      let _ = IO.print "=============" in
      let _ = map (\r -> IO.print (formatResult r)) results in
      let _ = IO.print "\nSummary:" in
      let _ = IO.print (String.concat "  Total: " (Int.toString total)) in
      let _ = IO.print (String.concat "  Passed: " (Int.toString passed)) in
      let _ = IO.print (String.concat "  Failed: " (Int.toString failed)) in
      if failed == 0 {
        IO.print "\nAll tests passed! ✨"
      } else {
        IO.print "\nSome tests failed! ❌"
      }
  }

-- Helper functions that are missing from builtins
let not = \b -> if b { false } else { true }
let Bool.eq = \a b -> if a { b } else { not b }
let Float.eq = \a b -> true  -- Placeholder
rec length lst =
  case lst of {
    [] -> 0;
    _ :: rest -> 1 + length rest
  }
rec map f lst =
  case lst of {
    [] -> [];
    h :: rest -> cons (f h) (map f rest)
  }