-- POSIX echo command implementation
-- echo prints arguments to stdout with a newline

import string

-- Join arguments with spaces
let joinArgs = fn args ->
  match args {
    [] -> ""
    [x] -> x
    x :: xs -> strConcat x (strConcat " " (joinArgs xs))
  }

-- Echo command implementation
let echo = fn args ->
  let message = joinArgs args in
  perform print message

-- Export for use in shell
echo