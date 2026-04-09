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
test "resume bad-call diagnostic carries effect-arm guidance" {
  let diag = TypeError::BadCall(
    message="resume used outside effect arm",
    span=test_span_typecheck_errors(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("`resume(...)`"))
      assert_true(hint.contains("`Error` boundary arms"))
    }
    None => fail("expected resume usage hint")
  }
}

///|
test "partial handle diagnostic carries missing-arm guidance" {
  let diag = TypeError::BadTypeDef(
    message="handle is missing handler for `Ask::B` (effect `Ask` is partially handled)",
    span=test_span_typecheck_errors(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("`Op(...) => ...`"))
      assert_true(hint.contains("`Result` boundary"))
    }
    None => fail("expected partial handle hint")
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
