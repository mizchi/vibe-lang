-- expect: "All tests completed!"
-- Test: Working test framework example

-- Run direct tests
let t1 = if eq (1 + 1) 2 {
  print "PASS: 1 + 1 = 2"
} else {
  print "FAIL: 1 + 1 = 2"
} in
            
let t2 = if eq (2 * 3) 6 {
  print "PASS: 2 * 3 = 6"
} else {
  print "FAIL: 2 * 3 = 6"
} in
            
let t3 = if strEq (strConcat "a" "b") "ab" {
  print "PASS: strConcat works"
} else {
  print "FAIL: strConcat works"
} in
            
let t4 = if eq (head [1, 2, 3]) 1 {
  print "PASS: head works"
} else {
  print "FAIL: head works"
} in
            
let t5 = if eq (head (tail [1, 2, 3])) 2 {
  print "PASS: tail works"
} else {
  print "FAIL: tail works"
} in
            
let t6 = if null [] {
  print "PASS: null works"
} else {
  print "FAIL: null works"
} in
            
let t7 = if eq 1 2 {
  print "PASS: This should fail"
} else {
  print "FAIL: This should fail"
} in

print "All tests completed!"