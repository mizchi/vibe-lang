;; Test car, cdr, null? functions
;; expect: true

;; Helper functions
(let not (fn (x) (if x false true)) in
(let and (fn (a b) (if a b false)) in

;; Test car (head)
(let lst1 (list 1 2 3) in
(let head1 (car lst1) in

;; Test cdr (tail)
(let tail1 (cdr lst1) in

;; Test null?
(let empty (list) in
(let non-empty (list 1) in

;; Check results
(let test1 (= head1 1) in
(let test2 (= (car tail1) 2) in
(let test3 (null? empty) in
(let test4 (not (null? non-empty)) in

;; All tests must pass
(and test1 (and test2 (and test3 test4)))))))))))))))