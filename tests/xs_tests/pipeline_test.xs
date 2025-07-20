; Pipeline operator tests  
; expect: true

(let inc (fn (x) (+ x 1)) in
  (let double (fn (x) (* x 2)) in
    (let add3 (fn (x) (+ x 3)) in
      
      ; Test manual pipeline equivalents
      (let test1 (= (double (inc 5)) 12) in
        (let test2 (= (double (inc (add3 10))) 28) in
          (let test3 (str-eq (int-to-string (inc (string-to-int "42"))) "43") in
            (let test4 (str-eq 
                         (str-concat "Number: " (int-to-string (inc (string-to-int "42"))))
                         "Number: 43") in
              
              ; All tests must pass
              (if test1
                  (if test2
                      (if test3
                          test4
                          false)
                      false)
                  false))))))))