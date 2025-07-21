; Basic test suite
; expect: true

; Test arithmetic operations
(let test1 (= (+ 2 2) 4) in
  (let test2 (= (* 3 4) 12) in
    (let test3 (= (- 10 5) 5) in
      (let test4 (= (/ 20 4) 5) in
        
        ; Test string operations
        (let test5 (str-eq (str-concat "Hello, " "World!") "Hello, World!") in
          (let test6 (= (string-length "hello") 5) in
            (let test7 (str-eq (int-to-string 42) "42") in
              (let test8 (= (string-to-int "123") 123) in
                
                ; Test lambda expressions
                (let test9 (= ((fn (x) x) 10) 10) in
                  (let test10 (= ((fn (x y) (+ x y)) 3 4) 7) in
                    
                    ; Test conditionals
                    (let test11 (= (if true 1 2) 1) in
                      (let test12 (= (if false 1 2) 2) in
                        
                        ; Test let bindings
                        (let x 10 in
                          (let y (+ x 5) in
                            (let test13 (= y 15) in
                              
                              ; Test lists
                              (let lst (list 1 2 3) in
                                (let test14 (match lst
                                              ((list h t) (= h 1))
                                              (_ false)) in
                                
                                  ; Test partial application
                                  (let add (fn (x y) (+ x y)) in
                                    (let add5 (add 5) in
                                      (let test15 (= (add5 3) 8) in
                                      
                                        ; All tests must pass
                                        (if test1
                                            (if test2
                                                (if test3
                                                    (if test4
                                                        (if test5
                                                            (if test6
                                                                (if test7
                                                                    (if test8
                                                                        (if test9
                                                                            (if test10
                                                                                (if test11
                                                                                    (if test12
                                                                                        (if test13
                                                                                            (if test14
                                                                                                test15
                                                                                                false)
                                                                                            false)
                                                                                        false)
                                                                                    false)
                                                                                false)
                                                                            false)
                                                                        false)
                                                                    false)
                                                                false)
                                                            false)
                                                        false)
                                                    false)
                                                false)
                                            false))))))))))))))))))))))