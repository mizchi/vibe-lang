; Test using minimal test framework

; Simple test
(let msg1 (strConcat "Test: " "1 + 1 = 2") in
(let result1 (= (+ 1 1) 2) in
(let x1 (if result1 (print "✓ 1 + 1 = 2") (print "✗ 1 + 1 = 2")) in

(let msg2 (strConcat "Test: " "2 * 3 = 6") in
(let result2 (= (* 2 3) 6) in
(let x2 (if result2 (print "✓ 2 * 3 = 6") (print "✗ 2 * 3 = 6")) in

(let msg3 (strConcat "Test: " "strConcat works") in
(let result3 (strEq (strConcat "a" "b") "ab") in
(let x3 (if result3 (print "✓ strConcat works") (print "✗ strConcat works")) in

(let msg4 (strConcat "Test: " "car works") in
(let result4 (= (car (list 1 2 3)) 1) in
(let x4 (if result4 (print "✓ car works") (print "✗ car works")) in

(let msg5 (strConcat "Test: " "This should fail") in
(let result5 (= 1 2) in
(let x5 (if result5 (print "✓ This should fail") (print "✗ This should fail")) in

(print "All tests executed!"))))))))))))))