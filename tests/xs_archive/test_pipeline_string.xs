-- Test pipeline with string operations
-- expect: "Number: 43"

"42" |> String.toInt |> (\x -> x + 1) |> Int.toString |> (\s -> String.concat "Number: " s)