-- Comprehensive test for list operations

-- Test car
let testCar1 = eq (List.car [1, 2, 3]) 1 in
let dummy1 = IO.print (if testCar1 { "✓ car [1,2,3] = 1" } else { "✗ car [1,2,3] = 1" }) in

-- Test cdr
let testCdr1 = let result = List.cdr [1, 2, 3] in
                 if List.null result {
                   false
                 } else {
                   eq (List.car result) 2
                 } in
let dummy2 = IO.print (if testCdr1 { "✓ cdr [1,2,3] starts with 2" } else { "✗ cdr [1,2,3] starts with 2" }) in

-- Test null?
let testNull1 = List.null [] in
let testNull2 = if List.null [1] { false } else { true } in
let dummy3 = IO.print (if testNull1 { "✓ null? [] = true" } else { "✗ null? [] = true" }) in
let dummy4 = IO.print (if testNull2 { "✓ null? [1] = false" } else { "✗ null? [1] = false" }) in

-- Test combination
let testCombo = eq (List.car (List.cdr [1, 2, 3])) 2 in
let dummy5 = IO.print (if testCombo { "✓ car (cdr [1,2,3]) = 2" } else { "✗ car (cdr [1,2,3]) = 2" }) in

-- Final result
let allPassed = if testCar1 {
                  if testCdr1 {
                    if testNull1 {
                      if testNull2 { testCombo } else { false }
                    } else {
                      false
                    }
                  } else {
                    false
                  }
                } else {
                  false
                } in
if allPassed {
  IO.print "\nAll tests passed!"
} else {
  IO.print "\nSome tests failed!"
}