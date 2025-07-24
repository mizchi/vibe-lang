-- Pipeline operator tests  
-- expect: true

let inc x = x + 1 in
let double x = x * 2 in
let add3 x = x + 3 in

-- Test pipeline operations
let test1 = 5 |> inc |> double = 12 in
let test2 = 10 |> add3 |> inc |> double = 28 in
let test3 = "42" |> String.toInt |> inc |> Int.toString = "43" in
let test4 = "42" 
  |> String.toInt 
  |> inc 
  |> Int.toString 
  |> String.concat "Number: "
  = "Number: 43" in

-- All tests must pass
test1 && test2 && test3 && test4