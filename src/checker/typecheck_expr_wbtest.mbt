///|
fn parse_first_expr_for_typecheck(script : String) -> @core.Expr raise {
  let ast = @parser.parse_ast(script)
  match ast.stmts {
    [@core.Stmt::Expr(expr~, ..)] => expr
    _ => fail("expected a single expression statement")
  }
}

///|
test "type_expr_eff: loop param purity tier is state_local" {
  let expr = parse_first_expr_for_typecheck("loop (i = 0) { break i }") catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let env = TypeEnv::new()
  let aliases : Map[String, @core.Ref] = {}
  let _ = type_expr_eff(env, expr, aliases, effect_scope_all(), true) catch {
    err => fail(err.to_string())
  }
  match env.get_purity_tier("i") {
    Some(tier) => assert_eq(tier, TopLevelPurityTier::StateLocal)
    None => fail("expected loop param purity tier")
  }
}

///|
test "type_check: handle resume value must match continuation destination type" {
  let script = "let run = () -> Int with { Error } {\n" +
    "  handle {\n" +
    "    let resumed: Int = perform(\"boom\")\n" +
    "    resumed\n" +
    "  } {\n" +
    "    Error(_) => resume(\"oops\")\n" +
    "  }\n" +
    "}"
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let result : Result[TypeEnv, TypeError] = try? type_check(ast)
  match result {
    Ok(_) => fail("expected resume value mismatch")
    Err(TypeError::Mismatch(expected~, actual~, context~, ..)) => {
      assert_eq(expected, @core.Type::Int)
      assert_eq(actual, @core.Type::String)
      assert_eq(context, Some("resume value"))
    }
    Err(err) => fail("unexpected type error: " + err.to_string())
  }
}

///|
test "type_check: recursive enum ctor payload keeps named references" {
  let script = "enum Expr { Lit(Int); Pair(Expr, Expr) }\n" +
    "let mk = (l: Expr, r: Expr) -> Expr { Pair(l, r) }"
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let env = type_check(ast) catch {
    err => fail("unexpected type error: \{err.to_string()}")
  }
  match env.get_ctor("Pair") {
    Some(info) =>
      match info.payload {
        @core.Type::Tuple(items) => {
          if items.length() != 2 {
            fail("expected Pair payload arity 2")
          }
          match items[0] {
            @core.Type::Named(name~, args~) => {
              assert_eq(name, "Expr")
              assert_eq(args.length(), 0)
            }
            other =>
              fail(
                "expected first payload element to stay named Expr, got \{other.to_string()}",
              )
          }
          match items[1] {
            @core.Type::Named(name~, args~) => {
              assert_eq(name, "Expr")
              assert_eq(args.length(), 0)
            }
            other =>
              fail(
                "expected second payload element to stay named Expr, got \{other.to_string()}",
              )
          }
        }
        other => fail("expected tuple payload, got \{other.to_string()}")
      }
    None => fail("missing Pair ctor info")
  }
}

///|
test "type_check: recorded expression type keeps recursive enum named" {
  let script = "enum Expr { Lit(Int); Pair(Expr, Expr) }\n" +
    "Pair(Lit(1), Lit(2))"
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let target_span = match ast.stmts {
    [@core.Stmt::EnumDef(..), @core.Stmt::Expr(expr~, ..)] => expr.span()
    _ => fail("expected enum definition followed by expression statement")
  }
  let env = type_check(ast) catch {
    err => fail("unexpected type error: \{err.to_string()}")
  }
  match env.get_expr_type(target_span) {
    Some(@core.Type::Named(name~, args~)) => {
      assert_eq(name, "Expr")
      assert_eq(args.length(), 0)
    }
    Some(other) =>
      fail(
        "expected recorded expression type to remain named Expr, got \{other.to_string()}",
      )
    None => fail("missing recorded expression type")
  }
}

///|
test "normalize_type cache: alias update invalidates cached normalization" {
  let env = TypeEnv::new()
  env.set_type_alias("Box", TypeAlias::{
    name: "Box",
    params: [],
    target: @core.Type::Int,
  })
  let box_ty = @core.Type::Named(name="Box", args=[])
  let first = normalize_type(env, box_ty) catch {
    err => fail("normalize failed: \{err.to_string()}")
  }
  assert_eq(first, @core.Type::Int)
  env.set_type_alias("Box", TypeAlias::{
    name: "Box",
    params: [],
    target: @core.Type::String,
  })
  let second = normalize_type(env, box_ty) catch {
    err => fail("normalize failed after alias update: \{err.to_string()}")
  }
  assert_eq(second, @core.Type::String)
}

///|
test "normalize_type: user alias overrides builtin Bytes" {
  let env = TypeEnv::new()
  // User defines Bytes as Array[Int], overriding the builtin Bytes type
  env.set_type_alias("Bytes", TypeAlias::{
    name: "Bytes",
    params: [],
    target: @core.Type::Array(@core.Type::Int),
  })
  let bytes_named = @core.Type::Named(name="Bytes", args=[])
  let resolved = normalize_type(env, bytes_named) catch {
    err => fail("normalize failed: \{err.to_string()}")
  }
  // User alias takes priority over builtin Bytes
  assert_eq(resolved, @core.Type::Array(@core.Type::Int))
}

///|
test "normalize_type: user alias overrides builtin Int" {
  let env = TypeEnv::new()
  env.set_type_alias("Int", TypeAlias::{
    name: "Int",
    params: [],
    target: @core.Type::Double,
  })
  let int_named = @core.Type::Named(name="Int", args=[])
  let resolved = normalize_type(env, int_named) catch {
    err => fail("normalize failed: \{err.to_string()}")
  }
  // User alias takes priority over builtin Int
  assert_eq(resolved, @core.Type::Double)
}

///|
test "normalize_type: builtin fallback when no user alias" {
  let env = TypeEnv::new()
  // No user alias for Int — should resolve via builtin fallback
  let int_named = @core.Type::Named(name="Int", args=[])
  let resolved = normalize_type(env, int_named) catch {
    err => fail("normalize failed: \{err.to_string()}")
  }
  assert_eq(resolved, @core.Type::Int)
}

///|
test "normalize_type: builtin Array fallback resolves inner type" {
  let env = TypeEnv::new()
  let arr_named = @core.Type::Named(name="Array", args=[
    @core.Type::Named(name="Int", args=[]),
  ])
  let resolved = normalize_type(env, arr_named) catch {
    err => fail("normalize failed: \{err.to_string()}")
  }
  assert_eq(resolved, @core.Type::Array(@core.Type::Int))
}

///|
test "normalize_type cache: expand and preserve enum caches are isolated" {
  let script = "enum Toggle { On; Off }"
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let env = type_check(ast) catch {
    err => fail("type check error: \{err.to_string()}")
  }
  let enum_ty = @core.Type::Named(name="Toggle", args=[])
  let preserved = normalize_type(env, enum_ty) catch {
    err => fail("preserve normalize failed: \{err.to_string()}")
  }
  assert_eq(preserved, enum_ty)
  let expanded = normalize_type_expand_enum(env, enum_ty) catch {
    err => fail("expand normalize failed: \{err.to_string()}")
  }
  match expanded {
    @core.Type::Variant(ctors) => {
      assert_true(ctors.contains("On"))
      assert_true(ctors.contains("Off"))
    }
    other => fail("expected variant expansion, got \{other.to_string()}")
  }
}

///|
test "type_check: for-in over String yields String elements" {
  let script =
    #|let main = () -> Array[String] {
    #|  let s = "hello"
    #|  for c in s {
    #|    c
    #|  }
    #|}
    #|main()
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let result : Result[TypeEnv, TypeError] = try? type_check(ast)
  match result {
    Ok(_) => () // type check passes — String for-in accepted
    Err(err) => fail("unexpected type error: " + err.to_string())
  }
}
