-- Test string operations
-- expect: true

let test1 = String.eq (String.concat "Hello, " "World!") "Hello, World!" in
let test2 = (String.length "hello") = 5 in
let test3 = String.eq (Int.toString 42) "42" in
let test4 = (String.toInt "123") = 123 in
  if test1 {
    if test2 {
      if test3 { test4 }
      else { false }
    } else { false }
  } else { false }