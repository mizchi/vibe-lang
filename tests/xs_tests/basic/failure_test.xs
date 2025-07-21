; Test that demonstrates failure cases
; expect: false

; This file intentionally contains failing tests
; Test 1: arithmetic failure
(let test1 (= 1 2) in

; Test 2: string comparison failure
(let test2 (str-eq "hello" "world") in

; Test 3: false condition
(let test3 false in

; Test 4: wrong list match
(let test4 (match (list 1 2 3)
             ((list 3 (list 2 (list 1 (list)))) true)
             (_ false)) in

; At least one test should fail
(if test1
    (if test2
        (if test3
            test4
            false)
        false)
    false)))))