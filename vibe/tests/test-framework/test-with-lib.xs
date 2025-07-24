; Test using the test library functions directly

; Helper functions from test.xs
(let not (fn (b) (if b false true)))

; Basic test of the not function
(let x1 (print "Testing not function:") in
(let x2 (print (not true)) in
(let x3 (print (not false)) in

; Test joinStrings
(rec joinStrings (strings sep)
  (match strings
    ((list) "")
    ((list s) s)
    ((list s ...rest) (strConcat s (strConcat sep (joinStrings rest sep))))))

(let x4 (print "Testing joinStrings:") in
(let x5 (print (joinStrings (list "a" "b" "c") ", ")) in

; Test typeName
(let typeName (fn (value)
  (match value
    ((Int _) "Int")
    ((Float _) "Float") 
    ((Bool _) "Bool")
    ((String _) "String")
    ((List _) "List")
    (_ "Unknown"))))

(let x6 (print "Testing typeName:") in
(let x7 (print (typeName 42)) in
(let x8 (print (typeName "hello")) in
(let x9 (print (typeName (list 1 2 3))) in
(let x10 (print (typeName true)) in

(print "All tests completed!"))))))))))