///|
fn assert_unify_rejects_recursive_var(ty : @core.Type) -> Unit raise {
  let env = TypeEnv::new()
  let ok = unify_types(env, @core.Type::Var(1), ty) catch {
    err => fail(err.to_string())
  }
  assert_false(ok)
}

///|
fn unify_test_type_check(script : String) -> TypeEnv raise {
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
}

///|
test "unify_types rejects recursive map key binding" {
  assert_unify_rejects_recursive_var(
    @core.Type::Map(@core.Type::Var(1), @core.Type::Int),
  )
}

///|
test "unify_types rejects recursive array builder binding" {
  assert_unify_rejects_recursive_var(
    @core.Type::ArrayBuilder(@core.Type::Var(1)),
  )
}

///|
test "unify_types rejects recursive map builder key binding" {
  assert_unify_rejects_recursive_var(
    @core.Type::MapBuilder(@core.Type::Var(1), @core.Type::Int),
  )
}

///|
test "unify_types rejects recursive map builder value binding" {
  assert_unify_rejects_recursive_var(
    @core.Type::MapBuilder(@core.Type::String, @core.Type::Var(1)),
  )
}

///|
test "unify_types terminates for expanded recursive enum against named enum" {
  let env = unify_test_type_check("enum Expr { Lit(Int); Pair(Expr, Expr) }")
  let named = @core.Type::Named(name="Expr", args=[])
  let expanded = normalize_type_expand_enum(env, named) catch {
    err => fail("normalize failed: \{err.to_string()}")
  }
  let ok = unify_types(env, expanded, named) catch {
    err => fail("unify failed: \{err.to_string()}")
  }
  assert_true(ok)
}

///|
test "type_check terminates for recursive compiler ast array push" {
  let _ = unify_test_type_check(
    (
      #|enum Pat {
      #|  PWild
      #|  PBind(String)
      #|  PCtor(String, Array[Pat])
      #|  PTuple(Array[Pat])
      #|}
      #|enum TypeExpr {
      #|  TyName(String)
      #|  TyApp(String, Array[TypeExpr])
      #|  TyFn(Array[TypeExpr], TypeExpr, Option[String])
      #|}
      #|enum Expr {
      #|  EInt(Int)
      #|  ETuple(Array[Expr])
      #|  EMatch(Expr, Array[(Pat, Expr)])
      #|  ECall(Expr, Array[Expr])
      #|  EFn(Array[String], Array[(String, Array[String])], Array[(String, Option[TypeExpr])], Option[TypeExpr], Option[String], Expr)
      #|}
      #|let push_expr = (dst: Array[Expr], value: Expr) -> Unit {
      #|  Array::push(dst, value)
      #|}
    ),
  )
}
