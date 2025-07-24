-- Test that demonstrates failure cases
-- expect: false

-- This file intentionally contains failing tests
-- Test 1: arithmetic failure
let test1 = eq 1 2 in

-- Test 2: string comparison failure
let test2 = String.eq "hello" "world" in

-- Test 3: false condition
let test3 = false in

-- Test 4: wrong list match
let test4 = case [1, 2, 3] of {
  [3, 2, 1] -> true
  _ -> false
} in

-- At least one test should fail
if test1 {
  if test2 {
    if test3 {
      test4
    } else {
      false
    }
  } else {
    false
  }
} else {
  false
}