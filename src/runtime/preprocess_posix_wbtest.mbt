///|
test "preprocess_posix_source: cat maps to Fs::read_file" {
  assert_eq(
    preprocess_posix_source("cat TODO.md"),
    "Fs::read_file(\"TODO.md\")",
  )
}

///|
test "preprocess_posix_source: ls maps to Fs::readdir" {
  assert_eq(preprocess_posix_source("ls /tmp"), "Fs::readdir(\"/tmp\")")
  assert_eq(preprocess_posix_source("ls"), "ls") // bare command, no args → unchanged
}

///|
test "preprocess_posix_source: echo returns string value" {
  assert_eq(preprocess_posix_source("echo hello world"), "\"hello world\"")
}

///|
test "preprocess_posix_source: unknown command falls to sh_lines" {
  assert_eq(preprocess_posix_source("git status"), "sh_lines(\"git status\")")
}

///|
test "preprocess_posix_source: keyword lines unchanged" {
  assert_eq(preprocess_posix_source("let x = 1"), "let x = 1")
  assert_eq(preprocess_posix_source("if true { 1 }"), "if true { 1 }")
  assert_eq(preprocess_posix_source("while true { }"), "while true { }")
  assert_eq(preprocess_posix_source("match x { _ => 0 }"), "match x { _ => 0 }")
  assert_eq(preprocess_posix_source("for x in xs { }"), "for x in xs { }")
  assert_eq(
    preprocess_posix_source("test { assert(true) }"),
    "test { assert(true) }",
  )
}

///|
test "preprocess_posix_source: function call unchanged" {
  assert_eq(preprocess_posix_source("print_line(\"hi\")"), "print_line(\"hi\")")
  assert_eq(preprocess_posix_source("Array::length(xs)"), "Array::length(xs)")
}

///|
test "preprocess_posix_source: assignment unchanged" {
  assert_eq(preprocess_posix_source("x = 1"), "x = 1")
}

///|
test "preprocess_posix_source: bare command no args unchanged" {
  assert_eq(preprocess_posix_source("ls"), "ls")
  assert_eq(preprocess_posix_source("echo"), "echo")
}

///|
test "preprocess_posix_source: non-ident start unchanged" {
  assert_eq(preprocess_posix_source("} else {"), "} else {")
  assert_eq(preprocess_posix_source("42"), "42")
}

///|
test "preprocess_posix_source: preserves indentation" {
  assert_eq(
    preprocess_posix_source("    cat TODO.md"),
    "    Fs::read_file(\"TODO.md\")",
  )
}

///|
test "preprocess_posix_source: multiline script" {
  assert_eq(
    preprocess_posix_source("let x = 1\ncat TODO.md\necho hello"),
    "let x = 1\nFs::read_file(\"TODO.md\")\n\"hello\"",
  )
}

///|
test "preprocess_posix_source: expression with operator unchanged" {
  assert_eq(preprocess_posix_source("x + y"), "x + y")
  assert_eq(preprocess_posix_source("x * y"), "x * y")
}

///|
test "preprocess_posix_source: cp maps to Fs::copy" {
  assert_eq(
    preprocess_posix_source("cp src.txt dst.txt"),
    "Fs::copy(\"src.txt\", \"dst.txt\")",
  )
}

///|
test "preprocess_posix_source: mv maps to Fs::rename" {
  assert_eq(
    preprocess_posix_source("mv old.txt new.txt"),
    "Fs::rename(\"old.txt\", \"new.txt\")",
  )
}

///|
test "preprocess_posix_source: cd maps to Fs::chdir" {
  assert_eq(preprocess_posix_source("cd /tmp"), "Fs::chdir(\"/tmp\")")
}

///|
test "preprocess_posix_source: rm maps to Fs::remove" {
  assert_eq(preprocess_posix_source("rm old.txt"), "Fs::remove(\"old.txt\")")
}

///|
test "preprocess_posix_source: pwd maps to Fs::getcwd" {
  // pwd with any arg is still treated as getcwd (args ignored)
  assert_eq(preprocess_posix_source("pwd ."), "Fs::getcwd()")
}

///|
test "preprocess_posix_source: env maps to Env::get" {
  assert_eq(preprocess_posix_source("env HOME"), "Env::get(\"HOME\")")
}

///|
test "preprocess_posix_source: exists maps to Fs::exists" {
  assert_eq(
    preprocess_posix_source("exists foo.txt"),
    "Fs::exists(\"foo.txt\")",
  )
}

