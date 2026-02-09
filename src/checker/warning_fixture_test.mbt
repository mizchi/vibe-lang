///|
fn render_warning_mismatch_for_test(
  mismatch : WarningFixtureMismatch,
) -> String {
  "[\{mismatch.source_path}] warning mismatch\nexpected:\n\{mismatch.expected}\n\nactual:\n\{mismatch.actual}"
}

///|
test "warning fixture diagnostics" {
  let mismatches = match verify_warning_fixtures("fixtures/warnings") {
    Ok(items) => items
    Err(err) => fail(err)
  }
  if mismatches.length() > 0 {
    let first = mismatches[0]
    fail(
      "[fixtures/warnings] mismatches: \{mismatches.length().to_string()}\n\{render_warning_mismatch_for_test(first)}",
    )
  }
}
