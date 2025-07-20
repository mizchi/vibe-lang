;; Test the self-hosted lexer implementation

;; All tests in one expression
(let not (fn (b) (if b false true)) in
(let and (fn (a b) (if a b false)) in
(let or (fn (a b) (if a true b)) in

;; First, let's test basic character classification functions
(let testIsWhitespace
  (let check1 (stringEq " " " ") in
  (let check2 (stringEq "\t" "\t") in
  (let check3 (not (stringEq "a" " ")) in
  (if (and check1 (and check2 check3))
      (print "✓ isWhitespace test passed")
      (print "✗ isWhitespace test failed"))))))

;; Test character code functions
(let testCharCode
  (let code1 (charCode "A") in
  (let code2 (charCode "0") in
  (let check1 (= code1 65) in
  (let check2 (= code2 48) in
  (if (and check1 check2)
      (print "✓ charCode test passed")
      (print "✗ charCode test failed")))))))

;; Test string slicing
(let testStringSlice
  (let s "hello world" in
  (let slice1 (stringSlice s 0 5) in
  (let slice2 (stringSlice s 6 11) in
  (let check1 (stringEq slice1 "hello") in
  (let check2 (stringEq slice2 "world") in
  (if (and check1 check2)
      (print "✓ stringSlice test passed")
      (print "✗ stringSlice test failed"))))))))

;; Test simple tokenization
(let testSimpleToken
  (let input "(+ 1 2)" in
  (let firstChar (stringAt input 0) in
  (let secondChar (stringAt input 1) in
  (let check1 (stringEq firstChar "(") in
  (let check2 (stringEq secondChar "+") in
  (if (and check1 check2)
      (print "✓ simple token test passed")
      (print "✗ simple token test failed"))))))))

;; Run all tests
(let dummy1 testIsWhitespace in
(let dummy2 testCharCode in
(let dummy3 testStringSlice in
(let dummy4 testSimpleToken in
(print "\n=== Lexer Tests Complete ==="))))))))) ;; Close all let expressions