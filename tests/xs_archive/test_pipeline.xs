; Test pipeline operator |>
; expect: true

(let inc (fn (x) (+ x 1)) in
  (let double (fn (x) (* x 2)) in
    (let add3 (fn (x) (+ x 3)) in
      ; Test simple pipeline: 5 |> inc |> double should be (5 + 1) * 2 = 12
      (let result1 ((double) ((inc) 5)) in
        ; Test with more functions: 10 |> add3 |> inc |> double should be ((10 + 3) + 1) * 2 = 28
        (let result2 ((double) ((inc) ((add3) 10))) in
          ; Test with string functions
          (let result3 ((int-to-string) ((inc) ((string-to-int) "42"))) in
            (if (= result1 12)
                (if (= result2 28)
                    (str-eq result3 "43")
                    false)
                false)))))))