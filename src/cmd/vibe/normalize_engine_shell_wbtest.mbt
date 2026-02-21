///| Shell-specific normalize engine tests (native only)

///|
test "normalize_engine: shell entry normalize drops unresolved top-level effect call" {
  let source =
    #|let f = (v: Int) { v * 2 }
    #|f(3)
    #|print("side")
    #|let x = 3
    #|let y = f(x)
  let result = normalize_source_text_with_entry_names_for_shell(source, [
    "x", "y",
  ])
  match result {
    Ok(normalized) => {
      assert_false(normalized.contains("print(\"side\")"))
      assert_true(normalized.contains("let x"))
      assert_true(normalized.contains("let y"))
      assert_true(normalized.contains("export { x, y }"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}
