; Test simple pipeline operator
; expect: 12

5 |> (fn (x) (+ x 1)) |> (fn (x) (* x 2))