-- Test pipeline operator |>
-- expect: true

let inc x = x + 1 in
let double x = x * 2 in
let add3 x = x + 3 in
-- Test simple pipeline: 5 |> inc |> double should be (5 + 1) * 2 = 12
let result1 = 5 |> inc |> double in
-- Test with more functions: 10 |> add3 |> inc |> double should be ((10 + 3) + 1) * 2 = 28
let result2 = 10 |> add3 |> inc |> double in
-- Test with string functions
let result3 = "42" |> String.toInt |> inc |> Int.toString in
  if result1 = 12 {
    if result2 = 28 {
      String.eq result3 "43"
    } else { false }
  } else { false }