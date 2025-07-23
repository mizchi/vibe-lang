-- Test simple pipeline operator
-- expect: 12

5 |> (\x -> x + 1) |> (\x -> x * 2)