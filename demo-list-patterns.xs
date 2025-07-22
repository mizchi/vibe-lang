; Demonstration of list pattern matching features

; 1. Empty list pattern
(match (list)
  ((list) "empty list matched")
  (_ "not empty"))

; 2. Single element extraction
(match (list 42)
  ((list x) x)
  (_ 0))

; 3. Head and tail pattern - get head
(match (list 1 2 3 4 5)
  ((list h ... t) h)
  (_ 0))

; 4. Head and tail pattern - get tail
(match (list 1 2 3 4 5)
  ((list h ... t) t)
  (_ (list)))

; 5. Multiple fixed elements with rest
(match (list 10 20 30 40 50)
  ((list a b c ... rest) (+ a (+ b c)))
  (_ 0))

; 6. Pattern with literals
(match (list 1 2 3)
  ((list 1 x 3) x)
  (_ 0))

; 7. Length function using pattern matching
(let length (rec len (lst)
  (match lst
    ((list) 0)
    ((list _ ... t) (+ 1 (len t))))))

(length (list 1 2 3 4 5))

; 8. Sum function using pattern matching
(let sum (rec sum (lst)
  (match lst
    ((list) 0)
    ((list h ... t) (+ h (sum t))))))

(sum (list 1 2 3 4 5))

; 9. Nested list patterns
(match (list (list 1 2) (list 3 4))
  ((list (list a b) (list c d)) (+ a (+ b (+ c d))))
  (_ 0))

; 10. Empty tail check
(match (list 42)
  ((list h ... t) (match t
                     ((list) "single element - empty tail")
                     (_ "has more elements")))
  (_ "no match"))