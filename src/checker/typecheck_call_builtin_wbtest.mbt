///|
fn builtin_test_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn builtin_test_string_arg(value : String) -> @core.CallArg {
  let span = builtin_test_span()
  @core.CallArg::{ label: None, expr: @core.Expr::String(value~, span~), span }
}

///|
fn builtin_test_ident_arg(name : String) -> @core.CallArg {
  let span = builtin_test_span()
  @core.CallArg::{ label: None, expr: @core.Expr::Ident(name~, span~), span }
}

///|
fn builtin_test_int_arg(value : Int) -> @core.CallArg {
  let span = builtin_test_span()
  @core.CallArg::{
    label: None,
    expr: @core.Expr::Int(value=value.to_int64(), span~),
    span,
  }
}

///|
test "type_call_builtin: path returns Path" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("./tmp")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "path",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Path)
}

///|
test "type_call_builtin: String::length returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("abc")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "String::length",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Int)
}

///|
test "type_call_builtin: array_new returns Array" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "array_new",
    [],
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  match actual {
    @core.Type::Array(_) => ()
    _ => fail("expected Array type")
  }
}

///|
test "type_call_builtin: PromptText::new accepts PromptText" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("p", @core.Type::PromptText)
  let args = [builtin_test_ident_arg("p")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "PromptText::new",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::PromptText)
}

///|
test "type_call_builtin: Llm::complete accepts PromptText" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("p", @core.Type::PromptText)
  let args = [builtin_test_string_arg("sys"), builtin_test_ident_arg("p")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Llm::complete",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::String)
}

///|
test "type_call_builtin: StringBuilder::push returns Unit" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("sb", @core.Type::StringBuilder)
  let args = [builtin_test_ident_arg("sb"), builtin_test_string_arg("x")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "StringBuilder::push",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Unit)
}

///|
test "type_call_builtin: ArrayBuilder::push returns Unit" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("ab", @core.Type::ArrayBuilder(@core.Type::String))
  let args = [builtin_test_ident_arg("ab"), builtin_test_string_arg("x")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "ArrayBuilder::push",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Unit)
}

///|
test "type_call_builtin: Json::get returns Json" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let json_ty = @core.Type::Named(name="Json", args=[])
  env.set("j", json_ty)
  let args = [builtin_test_ident_arg("j"), builtin_test_string_arg("key")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Json::get",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, json_ty)
}

///|
test "type_call_builtin: Http::listen returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_int_arg(8080)]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Http::listen",
    args,
    aliases,
    effect_scope_from_list([@core.EffectAtom::Const("Net")]),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Int)
}

///|
test "type_call_builtin: Http::accept returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_int_arg(1)]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Http::accept",
    args,
    aliases,
    effect_scope_from_list([@core.EffectAtom::Const("Net")]),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Int)
}

///|
test "type_call_builtin: Http::respond returns Unit" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [
    builtin_test_int_arg(2),
    builtin_test_int_arg(200),
    builtin_test_string_arg("content-type: text/plain"),
    builtin_test_string_arg("ok"),
  ]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Http::respond",
    args,
    aliases,
    effect_scope_from_list([@core.EffectAtom::Const("Net")]),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Unit)
}

///|
test "type_call_builtin: Http::listen requires Net effect" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_int_arg(8080)]
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Http::listen",
    args,
    aliases,
    effect_scope_from_list([]),
    true,
    span,
  )
  match result {
    Ok(_) => fail("expected effect guard error")
    Err(TypeError::EffectGuardNotSatisfied(operation~, missing_effect~, ..)) => {
      assert_eq(operation, "Http::listen")
      assert_eq(missing_effect, Some("Net"))
    }
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: unknown raises BadCall" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let args : Array[@core.CallArg] = []
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "not_builtin",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  )
  match result {
    Ok(_) => fail("expected BadCall")
    Err(TypeError::BadCall(message~, ..)) => assert_eq(message, "not_builtin")
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: sh accepts Process effect scope" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("echo ok")]
  let aliases : Map[String, @core.Ref] = {}
  let scope = effect_scope_from_list([@core.EffectAtom::Const("Process")])
  let actual = type_call_builtin(env, "sh", args, aliases, scope, true, span) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Unit)
}

///|
test "type_call_builtin: sh keeps Stdout compatibility" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("echo ok")]
  let aliases : Map[String, @core.Ref] = {}
  let scope = effect_scope_from_list([@core.EffectAtom::Const("Stdout")])
  let actual = type_call_builtin(env, "sh", args, aliases, scope, true, span) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Unit)
}

///|
test "type_call_builtin: Threads::spawn requires Threads effect" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("worker"), builtin_test_ident_arg("ch")]
  env.set("ch", @core.Type::Int)
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Threads::spawn",
    args,
    aliases,
    effect_scope_from_list([]),
    true,
    span,
  )
  match result {
    Ok(_) => fail("expected effect guard error")
    Err(TypeError::EffectGuardNotSatisfied(operation~, missing_effect~, ..)) => {
      assert_eq(operation, "Threads::spawn")
      assert_eq(missing_effect, Some("Threads"))
    }
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: Threads::spawn succeeds with Threads effect scope" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("worker"), builtin_test_ident_arg("ch")]
  env.set("ch", @core.Type::Int)
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Threads::spawn",
    args,
    aliases,
    effect_scope_from_list([@core.EffectAtom::Const("Threads")]),
    false,
    span,
  )
  match result {
    Ok(_) => ()
    Err(err) => fail("unexpected error: \{err.to_string()}")
  }
}
