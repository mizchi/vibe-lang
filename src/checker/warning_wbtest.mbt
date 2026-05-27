///|
fn warning_test_has_deprecated_fn_style(source : String) -> Bool {
  let ast = @parser.parse_ast(source) catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  collect_warnings(ast)
  .iter()
  .any(fn(diag) { diag.message.contains("deprecated function style") })
}

///|
test "warnings: canonical rec fn annotation is not deprecated style" {
  let source =
    #|let rec fact: (Int) -> Int = (n) -> {
    #|  if n < 2 { 1 } else { n * fact(n - 1) }
    #|}
    #|fact(3)
  assert_false(warning_test_has_deprecated_fn_style(source))
}

///|
test "warnings: canonical generic fn annotation is not deprecated style" {
  let source =
    #|let id: [T](T) -> T = (x) -> { x }
    #|id(1)
  assert_false(warning_test_has_deprecated_fn_style(source))
}

///|
test "warnings: old-style fn annotation is deprecated style" {
  let source =
    #|let inc = (x: Int) -> Int { x + 1 }
    #|inc(1)
  assert_true(warning_test_has_deprecated_fn_style(source))
}
