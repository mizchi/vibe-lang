///|
test "fallback: echo hello" {
  let result = execute_shell_lines_fallback("echo hello")
  assert_eq(result, ["hello"])
}

///|
test "fallback: echo no args" {
  let result = execute_shell_lines_fallback("echo")
  assert_eq(result, [""])
}

///|
test "fallback: empty command" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_eq(detail, "empty command")
}

///|
test "fallback: unsupported command" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("git status")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_true(detail.contains("not available on this target"))
  assert_true(detail.contains("fallback mode"))
}

///|
test "fallback: ls too many args" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("ls a b")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_eq(detail, "ls: expected 0 or 1 arguments, got 2")
}

///|
test "fallback: cat without file" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("cat")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_eq(detail, "cat: expected exactly 1 file argument, got 0")
}

///|
test "fallback: ls cwd" {
  let result = execute_shell_lines_fallback("ls .")
  assert_true(result.length() > 0)
}
