;; Test core functions that should be in standard library

;; Define core functions
(let not (fn (x) (if x false true)) in
(let and (fn (a b) (if a b false)) in
(let or (fn (a b) (if a true b)) in

;; elem function - check if element is in list
(rec elem (x lst)
  (match lst
    ((list) false)
    ((list h t) (if (= x h) true (elem x t))))) in

;; Tests
(let dummy1 (print "\n=== Core Functions Test ===") in

;; and tests
(let test1 (and true true) in
(let test2 (not (and true false)) in
(let test3 (not (and false true)) in
(let test4 (not (and false false)) in
(let dummy2 (print (if test1 "✓ and true true = true" "✗ and true true = true")) in
(let dummy3 (print (if test2 "✓ and true false = false" "✗ and true false = false")) in
(let dummy4 (print (if test3 "✓ and false true = false" "✗ and false true = false")) in
(let dummy5 (print (if test4 "✓ and false false = false" "✗ and false false = false")) in

;; or tests
(let test5 (or true true) in
(let test6 (or true false) in
(let test7 (or false true) in
(let test8 (not (or false false)) in
(let dummy6 (print (if test5 "✓ or true true = true" "✗ or true true = true")) in
(let dummy7 (print (if test6 "✓ or true false = true" "✗ or true false = true")) in
(let dummy8 (print (if test7 "✓ or false true = true" "✗ or false true = true")) in
(let dummy9 (print (if test8 "✓ or false false = false" "✗ or false false = false")) in

;; elem tests
(let test9 (elem 2 (list 1 2 3)) in
(let test10 (not (elem 4 (list 1 2 3))) in
(let test11 (not (elem 1 (list))) in
(let test12 (elem "hello" (list "world" "hello" "test")) in
(let dummy10 (print (if test9 "✓ elem 2 [1,2,3] = true" "✗ elem 2 [1,2,3] = true")) in
(let dummy11 (print (if test10 "✓ elem 4 [1,2,3] = false" "✗ elem 4 [1,2,3] = false")) in
(let dummy12 (print (if test11 "✓ elem 1 [] = false" "✗ elem 1 [] = false")) in
(let dummy13 (print (if test12 "✓ elem \"hello\" in list = true" "✗ elem \"hello\" in list = true")) in

;; Summary
(let all-tests (list test1 test2 test3 test4 test5 test6 test7 test8 test9 test10 test11 test12) in
(rec countTrue (lst)
  (match lst
    ((list) 0)
    ((list h t) (+ (if h 1 0) (countTrue t))))) in
(let passed (countTrue all-tests) in
(let failed (- 12 passed) in
(let dummy14 (print (strConcat "\nPassed: " (intToString passed))) in
(let dummy15 (print (strConcat "Failed: " (intToString failed))) in
(if (= failed 0)
    (print "\nAll tests passed! ✨")
    (print "\nSome tests failed! ❌")))))))))))))))))))))))))))))))))))