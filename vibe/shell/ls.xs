-- POSIX ls command implementation
-- ls lists directory contents

import string
import list

-- Parse ls options (simplified)
let parseOptions = fn args ->
  let isOption = fn arg ->
    match stringAt arg 0 {
      "-" -> true
      _ -> false
    } in
  let options = filter isOption args in
  let paths = filter (fn arg -> not (isOption arg)) args in
  { options: options, paths: paths }

-- List directory contents
-- Note: This requires builtin functions listDir and fileInfo to be implemented
let ls = fn args ->
  let parsed = parseOptions args in
  match parsed.paths {
    [] ->
      -- ls current directory
      -- Would need listDir builtin
      perform print "[ls requires listDir builtin]"
    paths ->
      -- ls specified paths
      let showPath = fn path ->
        perform print (strConcat "[ls " (strConcat path " requires listDir builtin]")) in
      map showPath paths
  }

-- Export for use in shell
ls