///|
fn test_span_typecheck_errors() -> @core.Span {
  { start: 0, end: 1 }
}

///|
test "trait sealed diagnostic carries openness code" {
  let diag = TypeError::TraitSealed(
    trait_name="Eq",
    span=test_span_typecheck_errors(),
  ).diagnostic()
  assert_true(diag.message.contains("[TROP001]"))
  assert_true(diag.message.contains("trait is sealed: Eq"))
}

///|
test "trait overlap diagnostic carries openness code" {
  let diag = TypeError::TraitImplOverlap(
    trait_name="Eq",
    span=test_span_typecheck_errors(),
  ).diagnostic()
  assert_true(diag.message.contains("[TROP003]"))
  assert_true(diag.message.contains("overlapping impl: Eq"))
}
