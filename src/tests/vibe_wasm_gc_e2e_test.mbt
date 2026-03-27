///|
test "wasm-gc e2e: return 42" {
  let src =
    #|let main = () -> Int { 42 }
    #|main()
  let (exit_code, output) = gc_e2e_compile_and_run(src, "return_42")
  if exit_code != 0 {
    fail("exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains("42") {
    fail("output should contain 42, got: \{output}")
  }
}

///|
test "wasm-gc e2e: arithmetic" {
  let src =
    #|let main = () -> Int { let x = 1; let y = 2; x + y }
    #|main()
  let (exit_code, output) = gc_e2e_compile_and_run(src, "arithmetic")
  if exit_code != 0 {
    fail("exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains("3") {
    fail("output should contain 3, got: \{output}")
  }
}

///|
test "wasm-gc e2e: if-else" {
  let src =
    #|let main = () -> Int { if true { 1 } else { 0 } }
    #|main()
  let (exit_code, output) = gc_e2e_compile_and_run(src, "if_else")
  if exit_code != 0 {
    fail("exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains("1") {
    fail("output should contain 1, got: \{output}")
  }
}
