;; Comprehensive test for list operations

;; Test car
(let test-car-1 (= (car (list 1 2 3)) 1) in
(let dummy1 (print (if test-car-1 "✓ car [1,2,3] = 1" "✗ car [1,2,3] = 1")) in

;; Test cdr
(let test-cdr-1 (let result (cdr (list 1 2 3)) in
                 (if (null? result)
                     false
                     (= (car result) 2))) in
(let dummy2 (print (if test-cdr-1 "✓ cdr [1,2,3] starts with 2" "✗ cdr [1,2,3] starts with 2")) in

;; Test null?
(let test-null-1 (null? (list)) in
(let test-null-2 (if (null? (list 1)) false true) in
(let dummy3 (print (if test-null-1 "✓ null? [] = true" "✗ null? [] = true")) in
(let dummy4 (print (if test-null-2 "✓ null? [1] = false" "✗ null? [1] = false")) in

;; Test combination
(let test-combo (= (car (cdr (list 1 2 3))) 2) in
(let dummy5 (print (if test-combo "✓ car (cdr [1,2,3]) = 2" "✗ car (cdr [1,2,3]) = 2")) in

;; Final result
(let all-passed (if test-car-1 
                    (if test-cdr-1 
                        (if test-null-1 
                            (if test-null-2 test-combo false)
                            false)
                        false)
                    false) in
(if all-passed
    (print "\nAll tests passed!")
    (print "\nSome tests failed!"))))))))))))))