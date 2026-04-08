///|
/// Helper: parse source and run rewrite_effect_handles
fn reh_parse_and_rewrite(source : String) -> @core.Module raise {
  let ast = @parser.parse_ast(source) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let aliases : Map[String, @core.Ref] = {}
  rewrite_effect_handles(desugar_method_calls(ast, aliases))
}

///|
/// Check if an AST contains any Perform nodes (should be 0 after rewriting builtins)
fn reh_has_perform(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Perform(..) => true
    @core.Expr::Call(args~, ..) => {
      for arg in args {
        if reh_has_perform(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if reh_has_perform(item) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      reh_has_perform(cond) ||
      reh_module_has_perform(then_body) ||
      reh_module_has_perform(else_body)
    @core.Expr::Block(body~, ..) => reh_module_has_perform(body)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if reh_has_perform(scrutinee) {
        return true
      }
      for arm in arms {
        if reh_has_perform(arm.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::While(cond~, body~, ..) =>
      reh_has_perform(cond) || reh_module_has_perform(body)
    @core.Expr::ForIn(iterable~, body~, ..) =>
      reh_has_perform(iterable) || reh_module_has_perform(body)
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if reh_has_perform(param.init) {
          return true
        }
      }
      reh_module_has_perform(body)
    }
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if reh_has_perform(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if reh_has_perform(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      if reh_module_has_perform(body) {
        return true
      }
      for arm in arms {
        if reh_has_perform(arm.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Fn(body~, ..) => reh_module_has_perform(body)
    @core.Expr::StringInterp(parts~, ..) => {
      for part in parts {
        match part {
          @core.StringInterpPart::Expr(e) =>
            if reh_has_perform(e) {
              return true
            }
          _ => ()
        }
      }
      false
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => reh_has_perform(v)
        None => false
      }
    @core.Expr::Continue(args~, ..) => {
      for arg in args {
        if reh_has_perform(arg) {
          return true
        }
      }
      false
    }
    @core.Expr::TupleIndex(expr=inner, ..)
    | @core.Expr::Yield(expr=inner, ..)
    | @core.Expr::Spread(expr=inner, ..) => reh_has_perform(inner)
    _ => false
  }
}

///|
fn reh_module_has_perform(m : @core.Module) -> Bool {
  for stmt in m.stmts {
    let found = match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::InternalExportLet(expr~, ..)
      | @core.Stmt::Expr(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..) => reh_has_perform(expr)
      @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
        reh_module_has_perform(body)
      _ => false
    }
    if found {
      return true
    }
  }
  false
}

///|
/// Helper: check if an AST contains a Call with the given name
fn reh_has_call_name(expr : @core.Expr, target : String) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if name == target {
        return true
      }
      for arg in args {
        if reh_has_call_name(arg.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if reh_has_call_name(item, target) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      reh_has_call_name(cond, target) ||
      reh_module_has_call_name(then_body, target) ||
      reh_module_has_call_name(else_body, target)
    @core.Expr::Block(body~, ..) => reh_module_has_call_name(body, target)
    @core.Expr::Handle(body~, arms~, ..) => {
      if reh_module_has_call_name(body, target) {
        return true
      }
      for arm in arms {
        if reh_has_call_name(arm.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::ForIn(iterable~, body~, ..) =>
      reh_has_call_name(iterable, target) ||
      reh_module_has_call_name(body, target)
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if reh_has_call_name(field.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Fn(body~, ..) => reh_module_has_call_name(body, target)
    _ => false
  }
}

///|
fn reh_module_has_call_name(m : @core.Module, target : String) -> Bool {
  for stmt in m.stmts {
    let found = match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::InternalExportLet(expr~, ..)
      | @core.Stmt::Expr(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..) => reh_has_call_name(expr, target)
      @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
        reh_module_has_call_name(body, target)
      _ => false
    }
    if found {
      return true
    }
  }
  false
}

///|
// Issue #239: builtin effect perform in Tuple is desugared to function call
test "reh: builtin perform in tuple is desugared" {
  let source =
    #|let pair = (perform Fs::ReadFile("a.txt"), perform Fs::ReadFile("b.txt"))
  let rewritten = reh_parse_and_rewrite(source)
  // After rewrite, Perform nodes should be replaced with Call("Fs::read_file", ...)
  assert_false(reh_module_has_perform(rewritten))
  assert_true(reh_module_has_call_name(rewritten, "Fs::read_file"))
}

///|
// Issue #239: builtin effect perform in Array is desugared
test "reh: builtin perform in array is desugared" {
  let source =
    #|let files = [perform Fs::ReadFile("a.txt"), perform Fs::ReadFile("b.txt")]
  let rewritten = reh_parse_and_rewrite(source)
  assert_false(reh_module_has_perform(rewritten))
  assert_true(reh_module_has_call_name(rewritten, "Fs::read_file"))
}

///|
// Issue #239: builtin effect perform in ForIn body is desugared
test "reh: builtin perform in for-in body is desugared" {
  let source =
    #|let files = ["a.txt", "b.txt"]
    #|for f in files {
    #|  perform Fs::ReadFile(f)
    #|}
  let rewritten = reh_parse_and_rewrite(source)
  assert_false(reh_module_has_perform(rewritten))
  assert_true(reh_module_has_call_name(rewritten, "Fs::read_file"))
}

///|
// Issue #239: builtin perform in Record fields is desugared
test "reh: builtin perform in record is desugared" {
  let source =
    #|let r = record { data: perform Fs::ReadFile("a.txt") }
  let rewritten = reh_parse_and_rewrite(source)
  assert_false(reh_module_has_perform(rewritten))
  assert_true(reh_module_has_call_name(rewritten, "Fs::read_file"))
}

///|
// Issue #239: builtin perform in string interpolation is desugared
test "reh: builtin perform in string interp is desugared" {
  let source =
    #|let s = "content: ${perform Fs::ReadFile("a.txt")}"
  let rewritten = reh_parse_and_rewrite(source)
  // Perform nodes inside StringInterp should be rewritten to function calls
  assert_false(reh_module_has_perform(rewritten))
}

///|
// Issue #239: user-defined perform in Tuple is inlined by handler
test "reh: user perform in tuple is inlined by handler" {
  let source =
    #|effect MyEff {
    #|  Op(Int) -> Int
    #|}
    #|handle {
    #|  let pair = (perform MyEff::Op(1), perform MyEff::Op(2))
    #|  pair
    #|} with MyEff {
    #|  Op(n) => resume(n * 10);
    #|}
  let rewritten = reh_parse_and_rewrite(source)
  // The perform MyEff::Op in the tuple should be inlined (replaced with handler body)
  // The Handle should still exist (for cross-function dispatch), but
  // the body's Perform nodes for MyEff::Op should be replaced with the inlined value
  let body_module = match rewritten.stmts[rewritten.stmts.length() - 1] {
    @core.Stmt::Expr(expr=@core.Expr::Handle(body~, ..), ..) => body
    _ => fail("expected Handle expr")
  }
  // The body should not have Perform nodes for MyEff::Op after inlining
  assert_false(reh_module_has_perform(body_module))
}

///|
// Issue #239: user-defined perform in Array is inlined by handler
test "reh: user perform in array is inlined by handler" {
  let source =
    #|effect MyEff {
    #|  Op(Int) -> Int
    #|}
    #|handle {
    #|  [perform MyEff::Op(1), perform MyEff::Op(2)]
    #|} with MyEff {
    #|  Op(n) => resume(n * 10);
    #|}
  let rewritten = reh_parse_and_rewrite(source)
  let body_module = match rewritten.stmts[rewritten.stmts.length() - 1] {
    @core.Stmt::Expr(expr=@core.Expr::Handle(body~, ..), ..) => body
    _ => fail("expected Handle expr")
  }
  assert_false(reh_module_has_perform(body_module))
}

///|
// Issue #239: user-defined perform in ForIn is inlined by handler
test "reh: user perform in for-in is inlined by handler" {
  let source =
    #|effect MyEff {
    #|  Op(Int) -> Unit
    #|}
    #|handle {
    #|  let items = [1, 2, 3]
    #|  for item in items {
    #|    perform MyEff::Op(item)
    #|  }
    #|} with MyEff {
    #|  Op(n) => resume(());
    #|}
  let rewritten = reh_parse_and_rewrite(source)
  let body_module = match rewritten.stmts[rewritten.stmts.length() - 1] {
    @core.Stmt::Expr(expr=@core.Expr::Handle(body~, ..), ..) => body
    _ => fail("expected Handle expr")
  }
  assert_false(reh_module_has_perform(body_module))
}

///|
// Issue #240: extract_resume_value_expr handles If in handler body
// (verified at codegen level — extract_resume_value_expr recursively processes If branches)
test "reh: handler with if-else containing resume is accepted" {
  let source =
    #|effect Transform {
    #|  Apply(Int) -> Int
    #|}
    #|handle {
    #|  perform Transform::Apply(5)
    #|} with Transform {
    #|  Apply(n) => if n > 0 { resume(n * 2) } else { resume(0) };
    #|}
  // Should parse and rewrite without error
  let rewritten = reh_parse_and_rewrite(source)
  // Handle should be preserved with the effect arm
  match rewritten.stmts[rewritten.stmts.length() - 1] {
    @core.Stmt::Expr(expr=@core.Expr::Handle(arms~, ..), ..) =>
      assert_true(arms.length() > 0)
    _ => fail("expected Handle expr")
  }
}

///|
// Issue #240: handler with Match containing resume
test "reh: handler with match containing resume is accepted" {
  let source =
    #|effect Transform {
    #|  Apply(Int) -> Int
    #|}
    #|handle {
    #|  perform Transform::Apply(5)
    #|} with Transform {
    #|  Apply(n) => match n {
    #|    0 => resume(0)
    #|    _ => resume(n * 2)
    #|  };
    #|}
  let rewritten = reh_parse_and_rewrite(source)
  match rewritten.stmts[rewritten.stmts.length() - 1] {
    @core.Stmt::Expr(expr=@core.Expr::Handle(arms~, ..), ..) =>
      assert_true(arms.length() > 0)
    _ => fail("expected Handle expr")
  }
}
