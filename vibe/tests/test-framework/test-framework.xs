(let t1 (= (+ 1 1) 2) in
(let x1 (if t1
            (print "PASS: 1 + 1 = 2")
            (print "FAIL: 1 + 1 = 2")) in
            
(let t2 (= (* 2 3) 6) in
(let x2 (if t2
            (print "PASS: 2 * 3 = 6")
            (print "FAIL: 2 * 3 = 6")) in
            
(let t3 (strEq (strConcat "a" "b") "ab") in
(let x3 (if t3
            (print "PASS: strConcat works")
            (print "FAIL: strConcat works")) in
            
(let t4 (= (car (list 1 2 3)) 1) in
(let x4 (if t4
            (print "PASS: car works")
            (print "FAIL: car works")) in
            
(let t5 (= (car (cdr (list 1 2 3))) 2) in
(let x5 (if t5
            (print "PASS: cdr works")
            (print "FAIL: cdr works")) in
            
(let t6 (null? (list)) in
(let x6 (if t6
            (print "PASS: null? works")
            (print "FAIL: null? works")) in
            
(let t7 (= 1 2) in
(let x7 (if t7
            (print "PASS: This should fail")
            (print "FAIL: This should fail")) in

(print "All tests completed!"))))))))))))))