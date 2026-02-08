///|
fn render_mismatch_for_test(mismatch : TypecheckFixtureMismatch) -> String {
  "[\{mismatch.source_path}] diagnostic mismatch\nexpected:\n\{mismatch.expected}\n\nactual:\n\{mismatch.actual}"
}

///|
test "typecheck fixture diagnostics" {
  let mismatches = match verify_typecheck_fixtures("fixtures/typecheck") {
    Ok(items) => items
    Err(err) => fail(err)
  }
  if mismatches.length() > 0 {
    let first = mismatches[0]
    fail(
      "[fixtures/typecheck] mismatches: \{mismatches.length().to_string()}\n\{render_mismatch_for_test(first)}",
    )
  }
}
