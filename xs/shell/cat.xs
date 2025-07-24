-- POSIX cat command implementation
-- cat concatenates and displays files

import string
import list

-- Read and display file contents
-- Note: This requires builtin function readFile to be implemented
let catFile = fn filename ->
  -- Would need readFile builtin
  perform print (strConcat "[cat " (strConcat filename " requires readFile builtin]"))

-- Cat command implementation
let cat = fn args ->
  match args {
    [] ->
      -- cat with no args reads from stdin
      -- Would need readStdin builtin
      perform print "[cat from stdin requires readStdin builtin]"
    files ->
      -- cat specified files
      map catFile files
  }

-- Export for use in shell
cat