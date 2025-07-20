; Simple literal and basic tests
; expect: true

(let test1 (= 42 42) in
  (let test2 (str-eq "hello" "hello") in
    (let test3 (if true true false) in
      (let test4 (if false false true) in
        (let lst (list 1 2 3) in
          (let test5 (match lst
                       ((list h t) (= h 1))
                       (_ false)) in
            (let test6 (= (+ 1 1) 2) in
              (let x 5 in
                (let y 10 in
                  (let test7 (= (+ x y) 15) in
                    (if test1
                        (if test2
                            (if test3
                                (if test4
                                    (if test5
                                        (if test6
                                            test7
                                            false)
                                        false)
                                    false)
                                false)
                            false)
                        false)))))))))))