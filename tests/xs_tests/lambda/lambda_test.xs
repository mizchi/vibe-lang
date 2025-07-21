; Lambda expression tests
; expect: true

(let test1 (= ((fn (x) x) 10) 10) in
  (let const42 (fn (x) 42) in
    (let test2 (= (const42 99) 42) in
      (let test3 (= ((fn (x y) (+ x y)) 3 4) 7) in
        (let f (fn (x) (fn (y) (+ x y))) in
          (let add5 (f 5) in
            (let test4 (= (add5 3) 8) in
              (let apply (fn (f x) (f x)) in
                (let double (fn (x) (* x 2)) in
                  (let test5 (= (apply double 21) 42) in
                    (let curry-add (fn (x) (fn (y) (+ x y))) in
                      (let add10 (curry-add 10) in
                        (let test6 (= (add10 32) 42) in
                          (let make-adder (fn (n) (fn (x) (+ x n))) in
                            (let add3 (make-adder 3) in
                              (let test7 (= (add3 7) 10) in
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
                                    false))))))))))))))))))