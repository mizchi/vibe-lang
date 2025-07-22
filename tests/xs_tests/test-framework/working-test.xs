; Working test framework example  

; Run direct tests
(let t1 (if (= (+ 1 1) 2)
            (print "PASS: 1 + 1 = 2")
            (print "FAIL: 1 + 1 = 2")) in
            
(let t2 (if (= (* 2 3) 6)
            (print "PASS: 2 * 3 = 6")
            (print "FAIL: 2 * 3 = 6")) in
            
(let t3 (if (str-eq (str-concat "a" "b") "ab")
            (print "PASS: str-concat works")
            (print "FAIL: str-concat works")) in
            
(let t4 (if (= (car (list 1 2 3)) 1)
            (print "PASS: car works")
            (print "FAIL: car works")) in
            
(let t5 (if (= (car (cdr (list 1 2 3))) 2)
            (print "PASS: cdr works")
            (print "FAIL: cdr works")) in
            
(let t6 (if (null? (list))
            (print "PASS: null? works")
            (print "FAIL: null? works")) in
            
(let t7 (if (= 1 2)
            (print "PASS: This should fail")
            (print "FAIL: This should fail")) in

(print "All tests completed!")))))))