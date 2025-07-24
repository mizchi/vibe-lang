;; Test simple lexer tokenization

;; Helper functions
(let and (fn (a b) (if a b false)) in

;; Import lexer components (simplified)
(let isWhitespace (fn (ch)
  (or (stringEq ch " ")
      (stringEq ch "	"))) in  ;; Tab character directly

(let isDigit (fn (ch)
  (and (>= (charCode ch) (charCode "0")) 
       (<= (charCode ch) (charCode "9")))) in

;; Test functions
(let test1 (isWhitespace " ") in
(let test2 (not (isWhitespace "a")) in
(let test3 (isDigit "5") in
(let test4 (not (isDigit "a")) in

(let allTests (and (and test1 test2) (and test3 test4)) in
(if allTests
    (print "✓ All lexer helper tests passed")
    (print "✗ Some lexer helper tests failed")))))))))))

;; Helper functions
(let or (fn (a b) (if a true b)) in
(let not (fn (b) (if b false true)))