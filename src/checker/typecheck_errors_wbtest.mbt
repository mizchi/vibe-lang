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

///|
test "placeholder bad-call diagnostic carries usage hint" {
  let diag = TypeError::BadCall(
    message="placeholder _ can only be used in function arguments",
    span=test_span_typecheck_errors(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("map(xs, _ + 1)"))
      assert_true(hint.contains("(x) ->"))
    }
    None => fail("expected placeholder usage hint")
  }
}

///|
test "top-level purity diagnostic shows state_local tier" {
  let diag = TypeError::TopLevelImpure(
    name="x",
    tier=TopLevelPurityTier::StateLocal,
    span=test_span_typecheck_errors(),
  ).diagnostic()
  match diag.note {
    Some(note) => assert_true(note.contains("state_local"))
    None => fail("expected state_local note")
  }
}

///|
test "top-level purity diagnostic hint for state_local" {
  let diag = TypeError::TopLevelImpure(
    name="x",
    tier=TopLevelPurityTier::StateLocal,
    span=test_span_typecheck_errors(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("do {"))
      assert_true(hint.contains("for"))
    }
    None => fail("expected hint")
  }
}

///|
test "scoped ref escape diagnostic carries guidance" {
  let diag = TypeError::ScopedRefEscape(
    context="function return",
    span=test_span_typecheck_errors(),
  ).diagnostic()
  assert_true(diag.message.contains("scoped Ref[T] cannot escape"))
  match diag.hint {
    Some(hint) => assert_true(hint.contains("return a pure value"))
    None => fail("expected scoped ref escape hint")
  }
  match diag.note {
    Some(note) => assert_true(note.contains("function return"))
    None => fail("expected scoped ref escape note")
  }
}
