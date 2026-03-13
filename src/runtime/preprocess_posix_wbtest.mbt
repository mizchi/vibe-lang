///|
test "preprocess_posix_source: command with dot in argument" {
  let input = "cat TODO.md"
  let result = preprocess_posix_source(input)
  assert_eq(result, "sh_lines(\"cat TODO.md\")")
}

///|
test "preprocess_posix_source: command with flags" {
  let input = "ls -la /tmp"
  let result = preprocess_posix_source(input)
  assert_eq(result, "sh_lines(\"ls -la /tmp\")")
}

///|
test "preprocess_posix_source: brace interpolation" {
  let input = "echo hello {{ name }}"
  let result = preprocess_posix_source(input)
  assert_eq(result, "sh_lines(\"echo hello \\{name}\")")
}

///|
test "preprocess_posix_source: command substitution" {
  let input = "echo $(date)"
  let result = preprocess_posix_source(input)
  assert_eq(
    result, "sh_lines(\"echo \\{{ match sh_lines(\"date\") { r if Array::length(r) > 0 => Array::get(r, 0), _ => \"\" } }}\")",
  )
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
  assert_eq(preprocess_posix_source("type Foo = Int"), "type Foo = Int")
  assert_eq(preprocess_posix_source("enum X { A; B }"), "enum X { A; B }")
  assert_eq(preprocess_posix_source("fn f() { 1 }"), "fn f() { 1 }")
  assert_eq(preprocess_posix_source("return 1"), "return 1")
  assert_eq(preprocess_posix_source("break"), "break")
  assert_eq(preprocess_posix_source("continue"), "continue")
  assert_eq(preprocess_posix_source("export let x = 1"), "export let x = 1")
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
test "preprocess_posix_source: pipe expression unchanged" {
  assert_eq(preprocess_posix_source("echo |> where(f)"), "echo |> where(f)")
}

///|
test "preprocess_posix_source: method call unchanged" {
  assert_eq(preprocess_posix_source("x .foo()"), "x .foo()")
}

///|
test "preprocess_posix_source: bare command no args unchanged" {
  // No args → leave for existing desugar
  assert_eq(preprocess_posix_source("ls"), "ls")
  assert_eq(preprocess_posix_source("echo"), "echo")
}

///|
test "preprocess_posix_source: non-ident start unchanged" {
  assert_eq(preprocess_posix_source("} else {"), "} else {")
  assert_eq(preprocess_posix_source("42"), "42")
  assert_eq(preprocess_posix_source("(1 + 2)"), "(1 + 2)")
}

///|
test "preprocess_posix_source: preserves indentation" {
  let input = "    cat TODO.md"
  let result = preprocess_posix_source(input)
  assert_eq(result, "    sh_lines(\"cat TODO.md\")")
}

///|
test "preprocess_posix_source: multiline script" {
  let input = "let x = 1\ncat TODO.md\necho hello"
  let result = preprocess_posix_source(input)
  assert_eq(
    result, "let x = 1\nsh_lines(\"cat TODO.md\")\nsh_lines(\"echo hello\")",
  )
}

///|
test "preprocess_posix_source: expression with operator unchanged" {
  assert_eq(preprocess_posix_source("x + y"), "x + y")
  assert_eq(preprocess_posix_source("x * y"), "x * y")
  assert_eq(preprocess_posix_source("x { y }"), "x { y }")
}

///|
test "preprocess_posix_source: escapes backslash and quotes" {
  let input = "echo hello\\world"
  let result = preprocess_posix_source(input)
  assert_eq(result, "sh_lines(\"echo hello\\\\world\")")
}

///|
test "preprocess_posix_source_with_compat_notes: rewritten command emits note" {
  let (result, notes) = preprocess_posix_source_with_compat_notes(
    "echo hello world",
  )
  assert_eq(result, "sh_lines(\"echo hello world\")")
  assert_eq(notes.length(), 1)
  assert_true(notes[0].contains("line 1"))
  assert_true(notes[0].contains("echo hello world"))
  assert_true(notes[0].contains("sh_lines(\"echo hello world\")"))
}

///|
test "preprocess_posix_source_with_compat_notes: unchanged script has no notes" {
  let (result, notes) = preprocess_posix_source_with_compat_notes(
    "let x = 1\nArray::length([x])",
  )
  assert_eq(result, "let x = 1\nArray::length([x])")
  assert_eq(notes.length(), 0)
}
