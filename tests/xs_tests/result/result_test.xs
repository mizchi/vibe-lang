-- Direct test execution

let not x = if x { false } else { true } in
let and a b = if a { b } else { false } in
let dummy1 = IO.print "\n=== Basic Tests ===" in

-- Test 1
let test1 = eq (1 + 1) 2 in
let dummy2 = IO.print (if test1 { "✓ 1 + 1 = 2" } else { "✗ 1 + 1 = 2" }) in

-- Test 2
let test2 = String.eq "hello" "hello" in
let dummy3 = IO.print (if test2 { "✓ string equality" } else { "✗ string equality" }) in

-- Test 3
let test3 = and true true in
let dummy4 = IO.print (if test3 { "✓ and true true" } else { "✗ and true true" }) in

-- Test 4
let test4 = not false in
let dummy5 = IO.print (if test4 { "✓ not false" } else { "✗ not false" }) in

-- Test 5
let test5 = String.eq (String.concat "hello" " world") "hello world" in
let dummy6 = IO.print (if test5 { "✓ string concat" } else { "✗ string concat" }) in

-- Summary
let passed = (if test1 { 1 } else { 0 }) + 
             (if test2 { 1 } else { 0 }) + 
             (if test3 { 1 } else { 0 }) + 
             (if test4 { 1 } else { 0 }) + 
             (if test5 { 1 } else { 0 }) in
let failed = 5 - passed in
let dummy7 = IO.print (String.concat "\nPassed: " (Int.toString passed)) in
let dummy8 = IO.print (String.concat "Failed: " (Int.toString failed)) in
if eq failed 0 {
  IO.print "\nAll tests passed! ✨"
} else {
  IO.print "\nSome tests failed! ❌"
}))