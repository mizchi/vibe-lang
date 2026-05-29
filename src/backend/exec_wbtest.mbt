///|
/// Regression for #412: `exec_command_capture` must not silently truncate
/// subprocess output that exceeds the old fixed 1 MB capture buffer.
test "exec_command_capture captures output larger than 1 MB" {
  // `seq 1 300000` emits 300000 lines (~2 MB), well past the old 1 MB cap.
  match exec_command_capture("seq 1 300000") {
    Ok((exit_code, lines)) => {
      assert_eq(exit_code, 0)
      assert_eq(lines.length(), 300000)
      assert_eq(lines[0], "1")
      assert_eq(lines[lines.length() - 1], "300000")
    }
    Err(e) => fail("expected capture to succeed, got: " + e)
  }
}

///|
test "exec_command_lines round-trips small output" {
  match exec_command_lines("printf 'a\\nb\\nc\\n'") {
    Ok(lines) => {
      assert_eq(lines.length(), 3)
      assert_eq(lines[0], "a")
      assert_eq(lines[1], "b")
      assert_eq(lines[2], "c")
    }
    Err(e) => fail("expected lines, got: " + e)
  }
}
