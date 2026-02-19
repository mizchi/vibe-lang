///|
test "TypeEnv::namespace_root resolves primitive and named roots" {
  let env = TypeEnv::new()
  assert_eq(env.namespace_root(@core.Type::Int), Some("Int"))
  assert_eq(env.namespace_root(@core.Type::String), Some("String"))
  assert_eq(
    env.namespace_root(@core.Type::Named(name="User", args=[])),
    Some("User"),
  )
}

///|
test "TypeEnv::namespace_root returns None for unsupported shapes" {
  let env = TypeEnv::new()
  let unit_root = env.namespace_root(@core.Type::Unit)
  assert_eq(unit_root, None)
  let variant_fields : Map[String, @core.Type] = {}
  variant_fields["Ctor"] = @core.Type::Int
  let variant_root = env.namespace_root(@core.Type::Variant(variant_fields))
  assert_eq(variant_root, None)
}
