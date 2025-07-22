;; Additional list operations for XS standard library

;; reverse - reverses a list
(let reverse (fn (lst)
  (let reverseHelper (rec reverseHelper (lst acc)
    (if (null? lst)
        acc
        (reverseHelper (cdr lst) (cons (car lst) acc)))) in
  (reverseHelper lst (list)))) in

;; append - concatenates two lists
(let append (rec append (xs ys)
  (if (null? xs)
      ys
      (cons (car xs) (append (cdr xs) ys)))) in

;; take - takes first n elements from a list
(let take (rec take (n lst)
  (if (= n 0)
      (list)
      (if (null? lst)
          (list)
          (cons (car lst) (take (- n 1) (cdr lst)))))) in

;; drop - drops first n elements from a list
(let drop (rec drop (n lst)
  (if (= n 0)
      lst
      (if (null? lst)
          (list)
          (drop (- n 1) (cdr lst))))) in

;; Export all functions
(list reverse append take drop)))))