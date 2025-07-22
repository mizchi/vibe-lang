(let test1 (= (+ 1 1) 2) in
(let r1 (if test1 (print "PASS: 1 + 1 = 2") (print "FAIL: 1 + 1 = 2")) in
(let test2 (= (* 2 3) 6) in
(let r2 (if test2 (print "PASS: 2 * 3 = 6") (print "FAIL: 2 * 3 = 6")) in
(let test3 (strEq (strConcat "a" "b") "ab") in
(let r3 (if test3 (print "PASS: strConcat") (print "FAIL: strConcat")) in
(let test4 (= (car (list 1 2 3)) 1) in
(let r4 (if test4 (print "PASS: car") (print "FAIL: car")) in
(let test5 (= (car (cdr (list 1 2 3))) 2) in
(let r5 (if test5 (print "PASS: cdr") (print "FAIL: cdr")) in
(let test6 (null? (list)) in
(let r6 (if test6 (print "PASS: null?") (print "FAIL: null?")) in
(let test7 (= 1 2) in
(let r7 (if test7 (print "PASS: 1 = 2") (print "FAIL: 1 = 2")) in
(print "Done"))))))))))))))