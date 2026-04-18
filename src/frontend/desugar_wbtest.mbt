///|
fn test_span() -> @core.Span {
  { start: 0, end: 0 }
}

///|
fn make_ident(name : String) -> @core.Expr {
  @core.Expr::Ident(name~, span=test_span())
}

///|
fn make_bool(value : Bool) -> @core.Expr {
  @core.Expr::Bool(value~, span=test_span())
}

///|
fn make_call(name : String, args : Array[@core.CallArg]) -> @core.Expr {
  @core.Expr::Call(name~, type_args=[], args~, span=test_span())
}

///|
fn make_arg(expr : @core.Expr, label? : String? = None) -> @core.CallArg {
  @core.CallArg::{ label, expr, span: test_span() }
}

///|
fn empty_scope() -> DesugarScope {
  DesugarScope::new()
}

///|
fn empty_known() -> Map[String, Bool] {
  known_vibe_non_command_names()
}

///|
test "try_extract_posix_command: bare ident (ls)" {
  let expr = make_ident("ls")
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  match result {
    Some((cmd, flags)) => {
      assert_eq(cmd, "ls")
      assert_eq(flags.length(), 0)
    }
    None => abort("expected Some")
  }
}

///|
test "try_extract_posix_command: known name (path) returns None" {
  let expr = make_ident("path")
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  assert_true(result is None)
}

///|
test "try_extract_posix_command: canonical MapBuilder name returns None" {
  let expr = make_ident("MapBuilder::new")
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  assert_true(result is None)
}

///|
test "try_extract_posix_command: legacy map_builder alias returns None" {
  let expr = make_ident("map_builder")
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  assert_true(result is None)
}

///|
test "try_extract_posix_command: __sub short flags (ls -al)" {
  // ls - al → __sub(Ident("ls"), Ident("al"))
  let expr = make_call("__sub", [
    make_arg(make_ident("ls")),
    make_arg(make_ident("al")),
  ])
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  match result {
    Some((cmd, flags)) => {
      assert_eq(cmd, "ls")
      assert_eq(flags.length(), 2)
      assert_eq(flags[0], "a")
      assert_eq(flags[1], "l")
    }
    None => abort("expected Some")
  }
}

///|
test "try_extract_posix_command: __sub __neg long flag (ls --all)" {
  // ls - (-all) → __sub(Ident("ls"), __neg(Ident("all")))
  let neg_all = make_call("__neg", [make_arg(make_ident("all"))])
  let expr = make_call("__sub", [make_arg(make_ident("ls")), make_arg(neg_all)])
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  match result {
    Some((cmd, flags)) => {
      assert_eq(cmd, "ls")
      assert_eq(flags.length(), 1)
      assert_eq(flags[0], "all")
    }
    None => abort("expected Some")
  }
}

///|
test "try_extract_posix_command: chained flags (ls -l -a)" {
  // ls - l - a → __sub(__sub(Ident("ls"), Ident("l")), Ident("a"))
  let inner = make_call("__sub", [
    make_arg(make_ident("ls")),
    make_arg(make_ident("l")),
  ])
  let expr = make_call("__sub", [make_arg(inner), make_arg(make_ident("a"))])
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  match result {
    Some((cmd, flags)) => {
      assert_eq(cmd, "ls")
      assert_eq(flags.length(), 2)
      assert_eq(flags[0], "l")
      assert_eq(flags[1], "a")
    }
    None => abort("expected Some")
  }
}

///|
test "try_extract_posix_command: long + short (ls --all -l)" {
  // __sub(__sub(Ident("ls"), __neg(Ident("all"))), Ident("l"))
  let neg_all = make_call("__neg", [make_arg(make_ident("all"))])
  let inner = make_call("__sub", [make_arg(make_ident("ls")), make_arg(neg_all)])
  let expr = make_call("__sub", [make_arg(inner), make_arg(make_ident("l"))])
  let result = try_extract_posix_command(expr, empty_scope(), empty_known())
  match result {
    Some((cmd, flags)) => {
      assert_eq(cmd, "ls")
      assert_eq(flags.length(), 2)
      assert_eq(flags[0], "all")
      assert_eq(flags[1], "l")
    }
    None => abort("expected Some")
  }
}

///|
test "try_all_labeled_args: all labeled" {
  let args = [
    make_arg(make_bool(true), label=Some("a")),
    make_arg(make_bool(true), label=Some("l")),
  ]
  assert_true(try_all_labeled_args(args))
}

///|
test "try_all_labeled_args: empty args" {
  let args : Array[@core.CallArg] = []
  assert_false(try_all_labeled_args(args))
}

///|
test "try_all_labeled_args: positional arg fails" {
  let args = [make_arg(make_bool(true))]
  assert_false(try_all_labeled_args(args))
}

///|
test "try_all_labeled_args: non-bool labeled passes (type check deferred)" {
  let args = [
    make_arg(@core.Expr::Int(value=1, span=test_span()), label=Some("a")),
  ]
  assert_true(try_all_labeled_args(args))
}

///|
test "desugar_vibe_commands: ls() → sh_lines no flags" {
  let call = make_call("ls", [])
  let ast = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=call, span=test_span())],
  }
  let (desugared, notes) = desugar_vibe_commands_with_notes(ast)
  assert_true(notes.length() > 0)
  match desugared.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name="sh_lines", args~, ..), ..) => {
      assert_eq(args.length(), 1)
      assert_true(args[0].label is None)
      match args[0].expr {
        @core.Expr::String(value~, ..) => assert_eq(value, "ls")
        _ => abort("expected String arg")
      }
    }
    _ => abort("expected sh_lines call")
  }
}

///|
test "desugar_vibe_commands: ls(l=true) → sh_lines with flag" {
  // Simulate: ls(l=true)
  let call = make_call("ls", [make_arg(make_bool(true), label=Some("l"))])
  let ast = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=call, span=test_span())],
  }
  let (desugared, notes) = desugar_vibe_commands_with_notes(ast)
  assert_true(notes.length() > 0)
  // Check the desugared output is a sh_lines call
  match desugared.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name="sh_lines", args~, ..), ..) => {
      // First arg: positional String "ls"
      assert_true(args[0].label is None)
      match args[0].expr {
        @core.Expr::String(value~, ..) => assert_eq(value, "ls")
        _ => abort("expected String arg")
      }
      // Second arg: labeled Bool l=true
      assert_eq(args[1].label, Some("l"))
      match args[1].expr {
        @core.Expr::Bool(value=true, ..) => ()
        _ => abort("expected Bool(true)")
      }
    }
    _ => abort("expected sh_lines call")
  }
}

///|
test "desugar_vibe_commands: ls(l=true, a=true) preserves order" {
  let call = make_call("ls", [
    make_arg(make_bool(true), label=Some("l")),
    make_arg(make_bool(true), label=Some("a")),
  ])
  let ast = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=call, span=test_span())],
  }
  let (desugared, _) = desugar_vibe_commands_with_notes(ast)
  match desugared.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name="sh_lines", args~, ..), ..) => {
      // Labels preserve input order: l, a
      assert_eq(args[1].label, Some("l"))
      assert_eq(args[2].label, Some("a"))
    }
    _ => abort("expected sh_lines call")
  }
}

///|
test "desugar_vibe_commands: ls -al → sh_lines with flags" {
  // __sub(Ident("ls"), Ident("al"))
  let expr = make_call("__sub", [
    make_arg(make_ident("ls")),
    make_arg(make_ident("al")),
  ])
  let ast = @core.Module::{ stmts: [@core.Stmt::Expr(expr~, span=test_span())] }
  let (desugared, notes) = desugar_vibe_commands_with_notes(ast)
  assert_true(notes.length() > 0)
  match desugared.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name="sh_lines", args~, ..), ..) => {
      // First arg: "ls"
      match args[0].expr {
        @core.Expr::String(value~, ..) => assert_eq(value, "ls")
        _ => abort("expected String")
      }
      // Flags sorted: a, l
      assert_eq(args[1].label, Some("a"))
      assert_eq(args[2].label, Some("l"))
    }
    _ => abort("expected sh_lines call")
  }
}

///|
test "desugar_vibe_commands: known name not desugared" {
  // path(a=true) should NOT be desugared (path is a builtin)
  let call = make_call("path", [make_arg(make_bool(true), label=Some("a"))])
  let ast = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=call, span=test_span())],
  }
  let (desugared, notes) = desugar_vibe_commands_with_notes(ast)
  assert_eq(notes.length(), 0)
  match desugared.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name="path", ..), ..) => ()
    _ => abort("expected path call unchanged")
  }
}

///|
test "split_method_call_name: single dot splits receiver and method" {
  match split_method_call_name("foo.bar") {
    Some((recv, method)) => {
      assert_eq(recv, "foo")
      assert_eq(method, "bar")
    }
    None => abort("expected Some")
  }
}

///|
test "split_method_call_name: no dot returns None" {
  assert_true(split_method_call_name("foo") is None)
}

///|
test "split_method_call_name: multi-dot returns None" {
  assert_true(split_method_call_name("foo.bar.baz") is None)
}

///|
test "split_method_call_name: leading dot returns None" {
  assert_true(split_method_call_name(".bar") is None)
}

///|
test "split_method_call_name: trailing dot returns None" {
  assert_true(split_method_call_name("foo.") is None)
}

///|
test "split_method_call_name: non-ident receiver returns None" {
  assert_true(split_method_call_name("foo-x.bar") is None)
}

///|
test "is_simple_ident: alnum and underscore pass" {
  assert_true(is_simple_ident("foo_Bar123"))
}

///|
test "is_simple_ident: empty rejected" {
  assert_false(is_simple_ident(""))
}

///|
test "is_simple_ident: hyphen rejected" {
  assert_false(is_simple_ident("foo-bar"))
}

///|
test "is_command_like_name: lowercase with digits accepted" {
  assert_true(is_command_like_name("ls"))
  assert_true(is_command_like_name("ls123"))
}

///|
test "is_command_like_name: empty rejected" {
  assert_false(is_command_like_name(""))
}

///|
test "is_command_like_name: uppercase first rejected" {
  assert_false(is_command_like_name("Ls"))
}

///|
test "is_command_like_name: digit first rejected" {
  assert_false(is_command_like_name("1ls"))
}

///|
test "is_command_like_name: underscore rejected" {
  assert_false(is_command_like_name("ls_all"))
}

///|
test "is_command_like_name: hyphen rejected" {
  assert_false(is_command_like_name("ls-all"))
}

///|
test "desugar_vibe_commands: identifier in scope stays untouched" {
  let let_stmt = @core.Stmt::Let(
    rec=false,
    name="ls",
    expr=@core.Expr::Int(value=1, span=test_span()),
    span=test_span(),
  )
  let call = make_call("ls", [])
  let expr_stmt = @core.Stmt::Expr(expr=call, span=test_span())
  let ast = @core.Module::{ stmts: [let_stmt, expr_stmt] }
  let (desugared, notes) = desugar_vibe_commands_with_notes(ast)
  assert_eq(notes.length(), 0)
  match desugared.stmts[1] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, ..), ..) => assert_eq(name, "ls")
    _ => abort("expected ls call unchanged")
  }
}
