-- Test combined string operations
-- expect: "The answer is: 42"
let count = 42 in
  let message = String.concat "The answer is: " (Int.toString count) in
    message