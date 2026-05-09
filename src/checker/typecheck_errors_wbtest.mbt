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
test "Mismatch hint suggests derive(Eq) when context includes no-impl-Eq" {
  // ADR-0045: typing `vec1 == vec2` where Vec2 has no Eq impl raises a
  // Mismatch with `context = "argument: no impl `Eq` for `Vec2`"`. The
  // diagnostic should point the user at `derive(Eq)`.
  let diag = TypeError::Mismatch(
    expected=@core.Type::Named(name="Eq", args=[]),
    actual=@core.Type::Named(name="Vec2", args=[]),
    span=test_span_typecheck_errors(),
    context=Some("argument: no impl `Eq` for `Vec2`"),
  ).diagnostic()
  match diag.hint {
    Some(hint) => assert_true(hint.contains("derive(Eq)"))
    None => fail("expected derive(Eq) hint")
  }
}

///|
test "Mismatch hint suggests derive(Hash) when context includes no-impl-Hash" {
  let diag = TypeError::Mismatch(
    expected=@core.Type::Named(name="Hash", args=[]),
    actual=@core.Type::Named(name="UserId", args=[]),
    span=test_span_typecheck_errors(),
    context=Some("argument: no impl `Hash` for `UserId`"),
  ).diagnostic()
  match diag.hint {
    Some(hint) => assert_true(hint.contains("derive(Hash)"))
    None => fail("expected derive(Hash) hint")
  }
}

///|
test "Mismatch hint omitted for plain (no trait-witness) context" {
  let diag = TypeError::Mismatch(
    expected=@core.Type::Int,
    actual=@core.Type::String,
    span=test_span_typecheck_errors(),
    context=Some("argument"),
  ).diagnostic()
  match diag.hint {
    Some(_) => fail("expected no hint for plain mismatch")
    None => ()
  }
}

///|
test "trait overlap diagnostic carries openness code and target details" {
  let diag = TypeError::TraitImplOverlap(
    trait_name="Eq",
    existing_target=@core.Type::Named(name="Foo", args=[]),
    incoming_target=@core.Type::Named(name="Bar", args=[]),
    span=test_span_typecheck_errors(),
  ).diagnostic()
  assert_true(diag.message.contains("[TROP003]"))
  assert_true(diag.message.contains("overlapping impl: Eq"))
  // Both targets surface so the user can see which impls conflict.
  assert_true(diag.message.contains("Bar"))
  match diag.note {
    Some(note) => {
      assert_true(note.contains("conflicts with existing impl"))
      assert_true(note.contains("Foo"))
    }
    None => fail("expected note with conflicting target")
  }
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
