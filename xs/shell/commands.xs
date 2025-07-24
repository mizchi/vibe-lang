-- POSIX Shell Commands Module
-- Exports all shell commands for use in XS shell

import shell.echo as Echo
import shell.pwd as Pwd
import shell.cd as Cd
import shell.ls as Ls
import shell.cat as Cat

-- Re-export all commands
let echo = Echo.echo
let pwd = Pwd.pwd
let cd = Cd.cd
let ls = Ls.ls
let cat = Cat.cat

-- Command dispatcher for shell integration
let runCommand = fn cmdName args ->
  match cmdName {
    "echo" -> echo args
    "pwd" -> pwd args
    "cd" -> cd args
    "ls" -> ls args
    "cat" -> cat args
    _ -> perform print (strConcat "Command not found: " cmdName)
  }

-- Export all commands and dispatcher
{ echo: echo, pwd: pwd, cd: cd, ls: ls, cat: cat, runCommand: runCommand }