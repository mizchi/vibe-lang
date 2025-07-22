(let t1 (= (+ 1 1) 2) in
(let r1 (if t1 (print "PASS: 1 + 1 = 2") (print "FAIL: 1 + 1 = 2")) in
(let t2 (= (* 2 3) 6) in
(let r2 (if t2 (print "PASS: 2 * 3 = 6") (print "FAIL: 2 * 3 = 6")) in
(let t3 (strEq (strConcat "hello" " world") "hello world") in
(let r3 (if t3 (print "PASS: strConcat") (print "FAIL: strConcat")) in
(let t4 (= (car (list 1 2 3)) 1) in
(let r4 (if t4 (print "PASS: car") (print "FAIL: car")) in
(let t5 (= (car (cdr (list 1 2 3))) 2) in
(let r5 (if t5 (print "PASS: cdr") (print "FAIL: cdr")) in
(let t6 (null? (list)) in
(let r6 (if t6 (print "PASS: null? empty") (print "FAIL: null? empty")) in
(let t7 (null? (list 1)) in
(let r7 (if t7 (print "FAIL: null? non-empty") (print "PASS: null? non-empty")) in
(print "All tests completed\!")))))))))))))
EOF < /dev/null