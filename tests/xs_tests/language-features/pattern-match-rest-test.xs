;; Test rest pattern matching

;; Helper function to sum a list
(let sum (rec sum (lst)
  (match lst
    ((list) 0)
    ((list x ...rest) (+ x (sum rest))))) in

;; Helper function to get first n elements
(let take-n (rec take-n (n lst)
  (match (list n lst)
    ((list 0 _) (list))
    ((list _ (list)) (list))
    ((list n (list x ...rest)) 
      (cons x (take-n (- n 1) rest))))) in

;; Test empty list pattern
(let test1 (match (list)
  ((list) "empty")
  ((list ...rest) "has rest")) in

;; Test single element with rest
(let test2 (match (list 1 2 3 4 5)
  ((list x ...rest) (list x rest))) in

;; Test multiple fixed elements with rest
(let test3 (match (list 1 2 3 4 5)
  ((list a b ...rest) (list a b rest))) in

;; Test sum function
(let test4 (sum (list 1 2 3 4 5)) in

;; Test take-n function
(let test5 (take-n 3 (list 1 2 3 4 5)) in

;; Print results
(let dummy1 (print "Test 1 (empty list):") in
(let dummy2 (print test1) in
(let dummy3 (print "\nTest 2 (x ...rest with [1,2,3,4,5]):") in
(let dummy4 (print test2) in
(let dummy5 (print "\nTest 3 (a b ...rest with [1,2,3,4,5]):") in
(let dummy6 (print test3) in
(let dummy7 (print "\nTest 4 (sum [1,2,3,4,5]):") in
(let dummy8 (print test4) in
(let dummy9 (print "\nTest 5 (take-n 3 [1,2,3,4,5]):") in
(let dummy10 (print test5) in

(print "\nRest pattern tests completed!"))))))))))))))