; Test basic functions needed for test framework

; Test print
(let x1 (print "=== Testing print ===") in

; Test strConcat
(let x2 (print (strConcat "Hello, " "World!")) in

; Test intToString
(let x3 (print (intToString 42)) in

; Test strEq
(let x4 (print "Testing strEq:") in
(let x5 (print (strEq "hello" "hello")) in
(let x6 (print (strEq "hello" "world")) in

; Test cons and list operations
(let x7 (print "Testing list operations:") in
(let lst (cons 1 (cons 2 (cons 3 (list)))) in
(let x8 (print lst) in

; Test car/cdr/null?
(let x9 (print (car lst)) in
(let x10 (print (cdr lst)) in
(let x11 (print (null? (list))) in
(let x12 (print (null? lst)) in

(print "All tests completed!"))))))))))))))