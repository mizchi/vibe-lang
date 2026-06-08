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
fn builtin_test_fn_param(name : String, ty : @core.Type) -> @core.FuncParam {
  { name, label: Positional, ty, bounds: [] }
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
test "type_call_builtin: String::from_char_codes returns String" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("codes", @core.Type::Array(@core.Type::Int))
  let args = [builtin_test_ident_arg("codes")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "String::from_char_codes",
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
test "type_call_builtin: __len returns Int for Bytes" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("b", @core.Type::Bytes)
  let args = [builtin_test_ident_arg("b")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "__len",
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
test "type_call: builtin __to_string beats local shadow" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("s", @core.Type::String)
  env.set(
    "__to_string",
    @core.Type::Func(
      params=[builtin_test_fn_param("n", @core.Type::Int)],
      ret=@core.Type::String,
      effects=[],
    ),
  )
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call(
    env,
    "__to_string",
    [builtin_test_ident_arg("s")],
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
      @debug.assert_eq(missing_effect, Some("Http"))
    }
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: Threads::runtime_hints returns runtime hint record" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Threads::runtime_hints",
    [],
    aliases,
    effect_scope_from_list([@core.EffectAtom::Const("Threads")]),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  match actual {
    @core.Type::Record(fields) => {
      @debug.assert_eq(
        fields.get("wasm_flags"),
        Some(@core.Type::Array(@core.Type::String)),
      )
      @debug.assert_eq(
        fields.get("wasi_flags"),
        Some(@core.Type::Array(@core.Type::String)),
      )
      @debug.assert_eq(fields.get("wasm_env"), Some(@core.Type::String))
      @debug.assert_eq(fields.get("wasi_env"), Some(@core.Type::String))
    }
    _ => fail("expected record type")
  }
}

///|
test "type_call_builtin: Threads builtins require Threads effect" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Threads::probe_wat",
    [],
    aliases,
    effect_scope_from_list([]),
    true,
    span,
  )
  match result {
    Ok(_) => fail("expected effect guard error")
    Err(TypeError::EffectGuardNotSatisfied(operation~, missing_effect~, ..)) => {
      assert_eq(operation, "Threads::probe_wat")
      @debug.assert_eq(missing_effect, Some("Threads"))
    }
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: Threads channel API has typed handle surface" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let scope = effect_scope_from_list([@core.EffectAtom::Const("Threads")])
  let task_handle_ty = @core.Type::Named(name="ThreadTask", args=[
    @core.Type::Int,
  ])
  let channel_ty = type_call_builtin(
    env,
    "Threads::channel_new",
    [builtin_test_int_arg(8)],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  match channel_ty {
    @core.Type::Named(name~, args~) => {
      assert_eq(name, "ThreadChannel")
      assert_eq(args.length(), 1)
    }
    _ => fail("expected ThreadChannel handle")
  }
  env.set("ch", channel_ty)
  let send_ty = type_call_builtin(
    env,
    "Threads::send",
    [builtin_test_ident_arg("ch"), builtin_test_string_arg("ok")],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(send_ty, @core.Type::Bool)
  let recv_ty = type_call_builtin(
    env,
    "Threads::recv",
    [builtin_test_ident_arg("ch")],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(recv_ty, @core.Type::String)
  let spawn_ty = type_call_builtin(
    env,
    "Threads::spawn",
    [builtin_test_string_arg("worker"), builtin_test_ident_arg("ch")],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(spawn_ty, task_handle_ty)
  env.set("task", spawn_ty)
  let wait_ty = type_call_builtin(
    env,
    "Threads::wait",
    [builtin_test_ident_arg("task")],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(wait_ty, @core.Type::Int)
}

///|
test "type_call_builtin: Threads channel payload is inferred from send" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let scope = effect_scope_from_list([@core.EffectAtom::Const("Threads")])
  let fields : Map[String, @core.Type] = {}
  fields["value"] = @core.Type::Int
  fields["label"] = @core.Type::String
  let record_ty = @core.Type::Record(fields)
  let channel_ty = type_call_builtin(
    env,
    "Threads::channel_new",
    [builtin_test_int_arg(8)],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  env.set("ch", channel_ty)
  env.set("msg", record_ty)
  let send_ty = type_call_builtin(
    env,
    "Threads::send",
    [builtin_test_ident_arg("ch"), builtin_test_ident_arg("msg")],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(send_ty, @core.Type::Bool)
  let recv_ty = type_call_builtin(
    env,
    "Threads::recv",
    [builtin_test_ident_arg("ch")],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  if !type_equal(env, recv_ty, record_ty) {
    fail("expected recv payload to match record type")
  }
}

///|
test "type_call_builtin: Threads recv requires constrained payload" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let scope = effect_scope_from_list([@core.EffectAtom::Const("Threads")])
  let channel_ty = type_call_builtin(
    env,
    "Threads::channel_new",
    [builtin_test_int_arg(8)],
    aliases,
    scope,
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  env.set("ch", channel_ty)
  let recv_result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Threads::recv",
    [builtin_test_ident_arg("ch")],
    aliases,
    scope,
    true,
    span,
  )
  match recv_result {
    Ok(_) => fail("expected unconstrained recv payload to be rejected")
    Err(TypeError::BadCall(message~, ..)) =>
      assert_true(message.contains("payload type must be constrained"))
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "type_call_builtin: Threads handles reject raw Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let scope = effect_scope_from_list([@core.EffectAtom::Const("Threads")])
  let send_result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Threads::send",
    [builtin_test_int_arg(1), builtin_test_string_arg("ok")],
    aliases,
    scope,
    true,
    span,
  )
  match send_result {
    Ok(_) => fail("expected raw Int channel handle to be rejected")
    Err(TypeError::Mismatch(expected~, actual~, ..)) => {
      assert_eq(
        expected,
        @core.Type::Named(name="ThreadChannel", args=[@core.Type::String]),
      )
      assert_eq(actual, @core.Type::Int)
    }
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
  let wait_result : Result[@core.Type, TypeError] = try? type_call_builtin(
    env,
    "Threads::wait",
    [builtin_test_int_arg(1)],
    aliases,
    scope,
    true,
    span,
  )
  match wait_result {
    Ok(_) => fail("expected raw Int task handle to be rejected")
    Err(TypeError::Mismatch(expected~, actual~, ..)) => {
      assert_eq(
        expected,
        @core.Type::Named(name="ThreadTask", args=[@core.Type::Int]),
      )
      assert_eq(actual, @core.Type::Int)
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

///|
test "type_call_builtin: v128_splat_i8x16 returns V128" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_int_arg(0x20)]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "v128_splat_i8x16",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::V128)
}

///|
test "type_call_builtin: v128_any_true returns Bool" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("v", @core.Type::V128)
  let args = [builtin_test_ident_arg("v")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "v128_any_true",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Bool)
}

///|
test "type_call_builtin: v128_bitmask_i8x16 returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("v", @core.Type::V128)
  let args = [builtin_test_ident_arg("v")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "v128_bitmask_i8x16",
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
test "type_call_builtin: v128_eq_i8x16 returns V128" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("a", @core.Type::V128)
  env.set("b", @core.Type::V128)
  let args = [builtin_test_ident_arg("a"), builtin_test_ident_arg("b")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "v128_eq_i8x16",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::V128)
}

///|
test "type_call_builtin: int_ctz returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let args = [builtin_test_int_arg(42)]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "int_ctz",
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
test "type_call_builtin: Set::new returns Set" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Set::new",
    [],
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  match actual {
    @core.Type::Set(_) => ()
    _ => fail("expected Set type")
  }
}

///|
test "type_call_builtin: Set::add returns Set" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("s", @core.Type::Set(@core.Type::Int))
  let args = [builtin_test_ident_arg("s"), builtin_test_int_arg(42)]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Set::add",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  match actual {
    @core.Type::Set(_) => ()
    _ => fail("expected Set type")
  }
}

///|
test "type_call_builtin: Set::contains returns Bool" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("s", @core.Type::Set(@core.Type::Int))
  let args = [builtin_test_ident_arg("s"), builtin_test_int_arg(42)]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Set::contains",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  assert_eq(actual, @core.Type::Bool)
}

///|
test "type_call_builtin: Set::size returns Int" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("s", @core.Type::Set(@core.Type::Int))
  let args = [builtin_test_ident_arg("s")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Set::size",
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
test "type_call_builtin: Set::to_array returns Array" {
  let env = TypeEnv::new()
  let span = builtin_test_span()
  env.set("s", @core.Type::Set(@core.Type::Int))
  let args = [builtin_test_ident_arg("s")]
  let aliases : Map[String, @core.Ref] = {}
  let actual = type_call_builtin(
    env,
    "Set::to_array",
    args,
    aliases,
    effect_scope_all(),
    true,
    span,
  ) catch {
    err => fail(err.to_string())
  }
  match actual {
    @core.Type::Array(_) => ()
    _ => fail("expected Array type, got " + actual.to_string())
  }
}
