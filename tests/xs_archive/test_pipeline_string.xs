; Test pipeline with string operations
; expect: "Number: 43"

"42" |> string-to-int |> (fn (x) (+ x 1)) |> int-to-string |> (fn (s) (str-concat "Number: " s))