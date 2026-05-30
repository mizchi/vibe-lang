///|
/// Round-trip the public binary-codec facade (issue #476 foundation):
/// writer -> bytes -> reader must reproduce every value, including a nested
/// `@core.Type`, in field order.
test "TypeBinWriter/TypeBinReader round-trip" {
  let ty : Type = Type::Func(
    params=[
      { name: "x", label: ParamLabel::Positional, ty: Type::Var(3), bounds: [] },
    ],
    ret=Type::Array(Type::Var(3)),
    effects=[EffectAtom::Const("Error")],
  )
  let w = TypeBinWriter::new()
  w.uint(42)
  w.int(-7)
  w.bool(true)
  w.str("hello")
  w.optstr(None)
  w.optstr(Some("opt"))
  w.ty(ty)
  let bytes = w.to_bytes()
  let r = TypeBinReader::new(bytes)
  assert_eq(r.uint(), 42)
  assert_eq(r.int(), -7)
  assert_eq(r.bool(), true)
  assert_eq(r.str(), "hello")
  assert_eq(r.optstr(), None)
  assert_eq(r.optstr(), Some("opt"))
  assert_eq(r.ty(), ty)
  assert_eq(r.remaining(), 0)
}
