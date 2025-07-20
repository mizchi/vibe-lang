; Test string operations
; expect: true

(let test1 (str-eq (str-concat "Hello, " "World!") "Hello, World!") in
  (let test2 (= (string-length "hello") 5) in
    (let test3 (str-eq (int-to-string 42) "42") in
      (let test4 (= (string-to-int "123") 123) in
        (if test1
            (if test2
                (if test3
                    test4
                    false)
                false)
            false)))))