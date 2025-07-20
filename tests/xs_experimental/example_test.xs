; Example test using XS test framework
; Tests are defined as expressions that should evaluate to true
; expect: true

; Helper function  
(let-rec length (lst)
  (match lst
    ((list) 0)
    ((list h rest) (+ 1 (length rest)))) in
    ; Test arithmetic operations
    (let test1 (= (+ 2 2) 4) in
      (let test2 (= (- 10 5) 5) in
        (let test3 (= (* 3 4) 12) in
          ; Test string operations
          (let test4 (str-eq (str-concat "Hello, " "World!") "Hello, World!") in
            (let test5 (= (string-length "hello") 5) in
              ; Test list operations
              (let test6 (= (length (list 1 2 3)) 3) in
                ; Combine all test results
                (if test1
                    (if test2
                        (if test3
                            (if test4
                                (if test5
                                    test6
                                    false)
                                false)
                            false)
                        false)
                    false)))))))))