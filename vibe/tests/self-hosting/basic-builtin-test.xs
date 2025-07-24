;; Basic test of builtin functions for self-hosting

;; Helper functions
(let and (fn (a b) (if a b false)) in

;; Test 1: stringAt
(let s "hello" in
(let char0 (stringAt s 0) in
(let char4 (stringAt s 4) in
(let test1 (and (stringEq char0 "h") (stringEq char4 "o")) in
(let result1 (if test1 
    (print "✓ stringAt test passed")
    (print "✗ stringAt test failed")) in

;; Test 2: charCode and codeChar
(let codeA (charCode "A") in
(let charFromCode (codeChar 65) in
(let test2 (and (= codeA 65) (stringEq charFromCode "A")) in
(let result2 (if test2
    (print "✓ charCode/codeChar test passed")
    (print "✗ charCode/codeChar test failed")) in

;; Test 3: stringSlice
(let text "hello world" in
(let slice1 (stringSlice text 0 5) in
(let slice2 (stringSlice text 6 11) in
(let test3 (and (stringEq slice1 "hello") (stringEq slice2 "world")) in
(let result3 (if test3
    (print "✓ stringSlice test passed")
    (print "✗ stringSlice test failed")) in

;; Test 4: toString
(let num 42 in
(let numStr (toString num) in
(let test4 (stringEq numStr "42") in
(let result4 (if test4
    (print "✓ toString test passed")
    (print "✗ toString test failed")) in

(print "\n=== Basic Tests Complete ===")))))))))))))))))))))) ;; 21 closing parens for all let expressions