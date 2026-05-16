///|
test "TypeEnv::namespace_root resolves primitive and named roots" {
  let env = TypeEnv::new()
  @debug.assert_eq(env.namespace_root(@core.Type::Int), Some("Int"))
  @debug.assert_eq(env.namespace_root(@core.Type::String), Some("String"))
  @debug.assert_eq(
    env.namespace_root(@core.Type::Named(name="User", args=[])),
    Some("User"),
  )
}

///|
test "TypeEnv::namespace_root returns None for unsupported shapes" {
  let env = TypeEnv::new()
  let unit_root = env.namespace_root(@core.Type::Unit)
  @debug.assert_eq(unit_root, None)
  let variant_fields : Map[String, @core.Type] = {}
  variant_fields["Ctor"] = @core.Type::Int
  let variant_root = env.namespace_root(@core.Type::Variant(variant_fields))
  @debug.assert_eq(variant_root, None)
}
