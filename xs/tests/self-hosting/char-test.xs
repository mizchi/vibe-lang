;; Test character classification functions

;; Helper functions
(let and (fn (a b) (if a b false)) in
(let or (fn (a b) (if a true b)) in
(let not (fn (b) (if b false true)) in

;; Test charCode
(let code0 (charCode "0") in
(let code9 (charCode "9") in
(let codeA (charCode "A") in
(let test1 (and (= code0 48) (and (= code9 57) (= codeA 65))) in

;; Test isDigit logic
(let isDigit (fn (ch)
  (let code (charCode ch) in
  (and (>= code 48) (<= code 57)))) in

(let test2 (and (isDigit "5") (not (isDigit "a"))) in

;; Test isWhitespace logic  
(let isWhitespace (fn (ch)
  (or (stringEq ch " ") (stringEq ch "	"))) in

(let test3 (and (isWhitespace " ") (not (isWhitespace "x"))) in

;; All tests
(let allPassed (and test1 (and test2 test3)) in
(if allPassed
    (print "✓ All character tests passed")
    (print "✗ Some character tests failed")))))))))))))))))