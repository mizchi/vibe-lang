-- POSIX cd command implementation
-- cd changes the current working directory

import string

-- Change directory
-- Note: This requires builtin functions setCwd and pathExists to be implemented
let cd = fn args ->
  match args {
    [] ->
      -- cd with no args goes to home directory
      -- Would need getHomeDir builtin
      perform print "[cd to home requires getHomeDir builtin]"
    [path] ->
      -- cd to specified path
      -- Would need setCwd builtin
      perform print (strConcat "[cd to " (strConcat path " requires setCwd builtin]"))
    _ ->
      perform print "cd: too many arguments"
  }

-- Export for use in shell
cd