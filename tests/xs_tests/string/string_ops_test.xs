; String operations tests
; expect: true

(let test1 (str-eq (str-concat "Hello, " "World!") "Hello, World!") in
  (let test2 (= (string-length "hello") 5) in
    (let test3 (= (string-length "") 0) in
      (let test4 (str-eq (int-to-string 42) "42") in
        (let test5 (str-eq (int-to-string -123) "-123") in
          (let test6 (= (string-to-int "123") 123) in
            (let test7 (str-eq "test" "test") in
              (let test8 (if (str-eq "hello" "world") false true) in
                (let s1 (str-concat "a" "b") in
                  (let s2 (str-concat s1 "c") in
                    (let test9 (str-eq s2 "abc") in
                      (let test10 (str-eq 
                                    (str-concat (str-concat "one" "two") "three")
                                    "onetwothree") in
                        (if test1
                            (if test2
                                (if test3
                                    (if test4
                                        (if test5
                                            (if test6
                                                (if test7
                                                    (if test8
                                                        (if test9
                                                            test10
                                                            false)
                                                        false)
                                                    false)
                                                false)
                                            false)
                                        false)
                                    false)
                                false)
                            false)))))))))))))