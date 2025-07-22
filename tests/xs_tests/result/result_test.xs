;; Direct test execution

(let not (fn (x) (if x false true)) in
(let and (fn (a b) (if a b false)) in
(let dummy1 (print "\n=== Basic Tests ===") in

;; Test 1
(let test1 (= (+ 1 1) 2) in
(let dummy2 (print (if test1 "✓ 1 + 1 = 2" "✗ 1 + 1 = 2")) in

;; Test 2
(let test2 (str-eq "hello" "hello") in
(let dummy3 (print (if test2 "✓ string equality" "✗ string equality")) in

;; Test 3
(let test3 (and true true) in
(let dummy4 (print (if test3 "✓ and true true" "✗ and true true")) in

;; Test 4
(let test4 (not false) in
(let dummy5 (print (if test4 "✓ not false" "✗ not false")) in

;; Test 5
(let test5 (str-eq (str-concat "hello" " world") "hello world") in
(let dummy6 (print (if test5 "✓ string concat" "✗ string concat")) in

;; Summary
(let passed (+ (if test1 1 0) 
              (+ (if test2 1 0) 
                 (+ (if test3 1 0) 
                    (+ (if test4 1 0) 
                       (if test5 1 0))))) in
(let failed (- 5 passed) in
(let dummy7 (print (str-concat "\nPassed: " (int-to-string passed))) in
(let dummy8 (print (str-concat "Failed: " (int-to-string failed))) in
(if (= failed 0)
    (print "\nAll tests passed! ✨")
    (print "\nSome tests failed! ❌"))))))))))))))))))))