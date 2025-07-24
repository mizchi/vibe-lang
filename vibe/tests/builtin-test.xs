;; Test new builtin functions

(let testProgram
  (let dummy1 (print "=== Testing stringAt ===") in
  (let s "hello" in
  (let dummy2 (print (stringAt s 0)) in  ; h
  (let dummy3 (print (stringAt s 1)) in  ; e
  (let dummy4 (print (stringAt s 4)) in  ; o

  (let dummy5 (print "\n=== Testing charCode ===") in
  (let dummy6 (print (charCode "A")) in   ; 65
  (let dummy7 (print (charCode "a")) in   ; 97
  (let dummy8 (print (charCode "0")) in   ; 48

  (let dummy9 (print "\n=== Testing codeChar ===") in
  (let dummy10 (print (codeChar 65)) in    ; A
  (let dummy11 (print (codeChar 97)) in    ; a
  (let dummy12 (print (codeChar 48)) in    ; 0

  (let dummy13 (print "\n=== Testing stringSlice ===") in
  (let text "hello world" in
  (let dummy14 (print (stringSlice text 0 5)) in   ; hello
  (let dummy15 (print (stringSlice text 6 11)) in  ; world
  (let dummy16 (print (stringSlice text 3 8)) in   ; lo wo

  (let dummy17 (print "\n=== Testing toString ===") in
  (let dummy18 (print (toString 42)) in       ; 42
  (let dummy19 (print (toString true)) in     ; true
  (let dummy20 (print (toString false)) in    ; false
  (let dummy21 (print (toString (list 1 2 3))) in ; [1, 2, 3]

  (let dummy22 (print "\n=== Testing stringConcat (lowerCamelCase) ===") in
  (let dummy23 (print (stringConcat "Hello" " World")) in  ; Hello World

  (let dummy24 (print "\n=== Testing stringEq (lowerCamelCase) ===") in
  (let dummy25 (print (stringEq "hello" "hello")) in  ; true
  (print (stringEq "hello" "world")))))))))))))))))))))))))))))))  ; false

testProgram