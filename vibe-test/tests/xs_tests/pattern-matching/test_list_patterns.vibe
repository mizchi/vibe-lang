-- expect: "All list pattern tests passed"
-- Test: List pattern matching features

-- Helper function to check test results
let assertEqual = fn actual expected testName ->
  if eq actual expected {
    true
  } else {
    error (strConcat testName " failed")
  }

-- Test empty list pattern
assertEqual
  (match [] {
    [] -> "empty"
    _ -> "not empty"
  })
  "empty"
  "empty list pattern"

-- Test single element pattern
assertEqual
  (match [42] {
    [x] -> x
    _ -> 0
  })
  42
  "single element pattern"

-- Test head and tail pattern
assertEqual
  (match [1, 2, 3, 4, 5] {
    h :: t -> h
    _ -> 0
  })
  1
  "head extraction with :: pattern"

-- Test tail extraction
assertEqual
  (match [1, 2, 3] {
    h :: t -> match t {
      [a, b] -> a + b
      _ -> 0
    }
    _ -> 0
  })
  5  -- 2 + 3
  "tail extraction"

-- Test pattern with fixed prefix
assertEqual
  (match [10, 20, 30, 40, 50] {
    [a, b, c, ...rest] -> a + b + c
    _ -> 0
  })
  60  -- 10 + 20 + 30
  "fixed prefix pattern"

-- Test literal in list pattern
assertEqual
  (match [1, 2, 3] {
    [1, x, 3] -> x
    _ -> 0
  })
  2
  "literal in list pattern"

-- Test nested list patterns
assertEqual
  (match [[1, 2], [3, 4]] {
    [[a, b], [c, d]] -> a + b + c + d
    _ -> 0
  })
  10  -- 1 + 2 + 3 + 4
  "nested list patterns"

-- Implement length function using pattern matching
let length = rec len lst ->
  match lst {
    [] -> 0
    _ :: t -> 1 + (len t)
  }

assertEqual (length [1, 2, 3, 4, 5]) 5 "length function"

-- Implement sum function using pattern matching
let sum = rec sum lst ->
  match lst {
    [] -> 0
    h :: t -> h + (sum t)
  }

assertEqual (sum [1, 2, 3, 4, 5]) 15 "sum function"

-- Test empty tail
assertEqual
  (match [42] {
    h :: t -> match t {
      [] -> "empty tail"
      _ -> "has elements"
    }
    _ -> "no match"
  })
  "empty tail"
  "single element has empty tail"

"All list pattern tests passed"