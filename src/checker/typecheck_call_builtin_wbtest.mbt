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
test "type_call_builtin: string_length returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("abc")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "string_length",
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
test "type_call_builtin: prompt_text accepts PromptText" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("p", @core.Type::PromptText)
  let args = [builtin_test_ident_arg("p")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "prompt_text",
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
test "type_call_builtin: llm_complete accepts PromptText" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("p", @core.Type::PromptText)
  let args = [builtin_test_string_arg("sys"), builtin_test_ident_arg("p")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "llm_complete",
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
test "type_call_builtin: string_builder_push returns Unit" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("sb", @core.Type::StringBuilder)
  let args = [builtin_test_ident_arg("sb"), builtin_test_string_arg("x")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "string_builder_push",
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
test "type_call_builtin: array_builder_push returns Unit" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("ab", @core.Type::ArrayBuilder(@core.Type::String))
  let args = [builtin_test_ident_arg("ab"), builtin_test_string_arg("x")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "array_builder_push",
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
test "type_call_builtin: json_get returns Json" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let json_ty = @core.Type::Named(name="Json", args=[])
  env.set("j", json_ty)
  let args = [builtin_test_ident_arg("j"), builtin_test_string_arg("key")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "json_get",
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
test "type_call_builtin: threads_spawn requires Threads effect" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("worker"), builtin_test_ident_arg("ch")]
  env.set("ch", @core.Type::Int)
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "threads_spawn",
    args,
    aliases,
    effect_scope_from_list([]),
    true,
    span,
  )
  match result {
    Ok(_) => fail("expected effect guard error")
    Err(TypeError::EffectGuardNotSatisfied(operation~, missing_effect~, ..)) => {
      assert_eq(operation, "threads_spawn")
      assert_eq(missing_effect, Some("Threads"))
    }
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: threads_spawn succeeds with Threads effect scope" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_string_arg("worker"), builtin_test_ident_arg("ch")]
  env.set("ch", @core.Type::Int)
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "threads_spawn",
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
