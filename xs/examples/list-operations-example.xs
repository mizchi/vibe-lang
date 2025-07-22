;; Test list-extras functions

;; Define reverse function
(let reverse-helper (rec reverse-helper (lst acc)
  (if (null? lst)
      acc
      (reverse-helper (cdr lst) (cons (car lst) acc)))) in

(let reverse (fn (lst) (reverse-helper lst (list))) in

;; Define append function
(let append (rec append (xs ys)
  (if (null? xs)
      ys
      (cons (car xs) (append (cdr xs) ys)))) in

;; Define take function
(let take (rec take (n lst)
  (if (= n 0)
      (list)
      (if (null? lst)
          (list)
          (cons (car lst) (take (- n 1) (cdr lst)))))) in

;; Define drop function
(let drop (rec drop (n lst)
  (if (= n 0)
      lst
      (if (null? lst)
          (list)
          (drop (- n 1) (cdr lst))))) in

;; Test data
(let lst1 (list 1 2 3 4 5) in
(let lst2 (list 6 7 8) in

;; Tests
(let dummy1 (print "\n=== List Extras Test ===") in

;; Test reverse
(let rev (reverse lst1) in
(let dummy2 (print "reverse [1,2,3,4,5]:") in
(let dummy3 (print rev) in

;; Test append
(let app (append lst1 lst2) in
(let dummy4 (print "\nappend [1,2,3,4,5] [6,7,8]:") in
(let dummy5 (print app) in

;; Test take
(let tk (take 3 lst1) in
(let dummy6 (print "\ntake 3 [1,2,3,4,5]:") in
(let dummy7 (print tk) in

;; Test drop
(let dr (drop 2 lst1) in
(let dummy8 (print "\ndrop 2 [1,2,3,4,5]:") in
(let dummy9 (print dr) in

;; Test edge cases
(let dummy10 (print "\n--- Edge Cases ---") in
(let dummy11 (print "reverse []:") in
(let dummy12 (print (reverse (list))) in
(let dummy13 (print "take 10 [1,2,3]:") in
(let dummy14 (print (take 10 (list 1 2 3))) in
(let dummy15 (print "drop 10 [1,2,3]:") in
(let dummy16 (print (drop 10 (list 1 2 3))) in

(print "\nAll tests completed!")))))))))))))))))))))))))))))