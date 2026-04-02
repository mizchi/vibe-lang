///|
fn type_check_for_monoify_test(ast : @core.Module) -> @checker.TypeEnv raise {
  let typed : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    ast,
  )
  match typed {
    Ok(env) => env
    Err(err) => fail("type error: \{err.to_string()}")
  }
}

///|
fn monoify_test_span(id : Int) -> @core.Span {
  { start: id * 10, end: id * 10 + 1 }
}

///|
fn monoify_test_num_type() -> @core.Type {
  @core.Type::Named(name="Num", args=[])
}

///|
fn monoify_test_num_param(name : String) -> @core.FuncParam {
  @core.FuncParam::{
    name,
    label: @core.ParamLabel::Positional,
    ty: monoify_test_num_type(),
    bounds: [],
  }
}

///|
fn monoify_test_arg(expr : @core.Expr, id : Int) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: monoify_test_span(id) }
}

///|
fn monoify_parse_and_desugar(source : String) -> @core.Module raise {
  let ast = @parser.parse_ast(source) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let aliases : Map[String, @core.Ref] = {}
  rewrite_effect_handles(desugar_method_calls(ast, aliases))
}

///|
fn monoify_expr_has_call_name(expr : @core.Expr, target : String) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if name == target {
        return true
      }
      for arg in args {
        if monoify_expr_has_call_name(arg.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if monoify_expr_has_call_name(item, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if monoify_expr_has_call_name(field.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if monoify_expr_has_call_name(field.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      monoify_expr_has_call_name(cond, target) ||
      monoify_module_has_call_name(then_body, target) ||
      monoify_module_has_call_name(else_body, target)
    @core.Expr::Block(body~, ..) => monoify_module_has_call_name(body, target)
    @core.Expr::Handle(body~, arms~, ..) => {
      if monoify_module_has_call_name(body, target) {
        return true
      }
      for arm in arms {
        if monoify_expr_has_call_name(arm.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if monoify_expr_has_call_name(scrutinee, target) {
        return true
      }
      for arm in arms {
        if monoify_expr_has_call_name(arm.expr, target) {
          return true
        }
      }
      false
    }
    @core.Expr::While(cond~, body~, ..) =>
      monoify_expr_has_call_name(cond, target) ||
      monoify_module_has_call_name(body, target)
    @core.Expr::Loop(body~, ..) => monoify_module_has_call_name(body, target)
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) => monoify_expr_has_call_name(inner, target)
        None => false
      }
    @core.Expr::Continue(args~, ..) => {
      for item in args {
        if monoify_expr_has_call_name(item, target) {
          return true
        }
      }
      false
    }
    @core.Expr::Fn(body~, ..) => monoify_module_has_call_name(body, target)
    _ => false
  }
}

///|
fn monoify_expr_has_call_prefix(expr : @core.Expr, prefix : String) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if name.has_prefix(prefix) {
        return true
      }
      for arg in args {
        if monoify_expr_has_call_prefix(arg.expr, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if monoify_expr_has_call_prefix(item, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if monoify_expr_has_call_prefix(field.expr, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if monoify_expr_has_call_prefix(field.expr, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      monoify_expr_has_call_prefix(cond, prefix) ||
      monoify_module_has_call_prefix(then_body, prefix) ||
      monoify_module_has_call_prefix(else_body, prefix)
    @core.Expr::Block(body~, ..) => monoify_module_has_call_prefix(body, prefix)
    @core.Expr::Handle(body~, arms~, ..) => {
      if monoify_module_has_call_prefix(body, prefix) {
        return true
      }
      for arm in arms {
        if monoify_expr_has_call_prefix(arm.expr, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if monoify_expr_has_call_prefix(scrutinee, prefix) {
        return true
      }
      for arm in arms {
        if monoify_expr_has_call_prefix(arm.expr, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::While(cond~, body~, ..) =>
      monoify_expr_has_call_prefix(cond, prefix) ||
      monoify_module_has_call_prefix(body, prefix)
    @core.Expr::Loop(body~, ..) => monoify_module_has_call_prefix(body, prefix)
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) => monoify_expr_has_call_prefix(inner, prefix)
        None => false
      }
    @core.Expr::Continue(args~, ..) => {
      for item in args {
        if monoify_expr_has_call_prefix(item, prefix) {
          return true
        }
      }
      false
    }
    @core.Expr::Fn(body~, ..) => monoify_module_has_call_prefix(body, prefix)
    _ => false
  }
}

///|
fn monoify_module_has_call_name(body : @core.Module, target : String) -> Bool {
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::InternalExportLet(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..)
      | @core.Stmt::Assign(expr~, ..)
      | @core.Stmt::Expr(expr~, ..) =>
        if monoify_expr_has_call_name(expr, target) {
          return true
        }
      @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
        if monoify_module_has_call_name(body, target) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn monoify_module_has_call_prefix(body : @core.Module, prefix : String) -> Bool {
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::InternalExportLet(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..)
      | @core.Stmt::Assign(expr~, ..)
      | @core.Stmt::Expr(expr~, ..) =>
        if monoify_expr_has_call_prefix(expr, prefix) {
          return true
        }
      @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
        if monoify_module_has_call_prefix(body, prefix) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
test "monoify_module rewrites local Num add call to specialized symbol" {
  let x_ident = @core.Expr::Ident(name="x", span=monoify_test_span(1))
  let y_ident = @core.Expr::Ident(name="y", span=monoify_test_span(2))
  let add_body_call = @core.Expr::Call(
    name="__add",
    type_args=[],
    args=[monoify_test_arg(x_ident, 3), monoify_test_arg(y_ident, 4)],
    span=monoify_test_span(5),
  )
  let add_fn_expr = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[monoify_test_num_param("x"), monoify_test_num_param("y")],
    ret=Some(monoify_test_num_type()),
    effects=[],
    body={
      stmts: [@core.Stmt::Expr(expr=add_body_call, span=monoify_test_span(6))],
    },
    span=monoify_test_span(7),
  )
  let value_expr = @core.Expr::Call(
    name="add",
    type_args=[],
    args=[
      monoify_test_arg(@core.Expr::Int(value=1L, span=monoify_test_span(8)), 9),
      monoify_test_arg(
        @core.Expr::Int(value=2L, span=monoify_test_span(10)),
        11,
      ),
    ],
    span=monoify_test_span(12),
  )
  let ast : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="add",
        expr=add_fn_expr,
        span=monoify_test_span(13),
      ),
      @core.Stmt::Let(
        rec=false,
        name="value",
        expr=value_expr,
        span=monoify_test_span(14),
      ),
    ],
  }
  let env = type_check_for_monoify_test(ast)
  let result = monoify_module(ast, env.expr_type_index())
  assert_true(result.instantiations.contains("add:i32"))
  let mut has_specialized_def = false
  let mut value_calls_specialized = false
  for stmt in result.ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) => {
        if name == "add$i32" {
          has_specialized_def = true
        }
        if name == "value" {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              if call_name == "add$i32" {
                value_calls_specialized = true
              }
            _ => ()
          }
        }
      }
      _ => ()
    }
  }
  assert_true(has_specialized_def)
  assert_true(value_calls_specialized)
}

///|
test "monoify_module specializes iterable dispatch call sites by concrete root" {
  let ast = monoify_parse_and_desugar(
    "enum Trio[T] { Trio(T, T, T) }\n" +
    "impl [T] Iterable for Trio[T]\n" +
    "let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] { Trio(a, b, c) }\n" +
    "let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }\n" +
    "let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {\n" +
    "  match xs {\n" +
    "    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }\n" +
    "  }\n" +
    "}\n" +
    "let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {\n" +
    "  let len = xs|>iter_length\n" +
    "  let mut i = 0\n" +
    "  let mut acc = init\n" +
    "  while i < len {\n" +
    "    acc = f(acc, xs|>iter_get(i))\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  acc\n" +
    "}\n" +
    "let value = Iterator::fold(trio_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })\n",
  )
  let env = type_check_for_monoify_test(ast)
  let result = monoify_module(ast, env.expr_type_index())
  let mut has_fold_trio_inst = false
  for key, _ in result.instantiations {
    if key.has_prefix("Iterator::fold:Trio") {
      has_fold_trio_inst = true
    }
  }
  assert_true(has_fold_trio_inst)
  let mut has_specialized_def = false
  let mut value_calls_specialized = false
  let mut body_calls_trio_length = false
  let mut body_calls_trio_get = false
  let mut body_calls_plain_iter_get = false
  for stmt in result.ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) => {
        if name.has_prefix("Iterator::fold$Trio") {
          has_specialized_def = true
          match expr {
            @core.Expr::Fn(body~, ..) => {
              body_calls_trio_length = monoify_module_has_call_prefix(
                body, "Trio::iter_length",
              )
              body_calls_trio_get = monoify_module_has_call_prefix(
                body, "Trio::iter_get",
              )
              body_calls_plain_iter_get = monoify_module_has_call_name(
                body, "iter_get",
              )
            }
            _ => ()
          }
        }
        if name == "value" {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              if call_name.has_prefix("Iterator::fold$Trio") {
                value_calls_specialized = true
              }
            _ => ()
          }
        }
      }
      _ => ()
    }
  }
  assert_true(has_specialized_def)
  assert_true(value_calls_specialized)
  assert_true(body_calls_trio_length)
  if !body_calls_trio_get {
    fail(
      "expected Trio::iter_get rewrite, plain iter_get=" +
      body_calls_plain_iter_get.to_string(),
    )
  }
}

///|
test "monoify_module specializes list iterable helper transitively" {
  let ast = monoify_parse_and_desugar(
    "enum List[T] { Nil; Cons(T, List[T]) }\n" +
    "impl [T] Iterable for List[T]\n" +
    "let list_of3 = [T](a: T, b: T, c: T) -> List[T] { Cons(a, Cons(b, Cons(c, Nil))) }\n" +
    "let rec list_length = [T](xs: List[T]) -> Int {\n" +
    "  match xs {\n" +
    "    Nil => 0,\n" +
    "    Cons(_, t) => 1 + list_length(t)\n" +
    "  }\n" +
    "}\n" +
    "let rec list_iter_get = [T](xs: List[T], index: Int) -> T {\n" +
    "  match xs {\n" +
    "    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },\n" +
    "    Nil => list_iter_get(xs, index)\n" +
    "  }\n" +
    "}\n" +
    "let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }\n" +
    "let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }\n" +
    "let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {\n" +
    "  let len = xs|>iter_length\n" +
    "  let mut i = 0\n" +
    "  let mut acc = init\n" +
    "  while i < len {\n" +
    "    acc = f(acc, xs|>iter_get(i))\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  acc\n" +
    "}\n" +
    "let value = Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })\n",
  )
  let env = type_check_for_monoify_test(ast)
  let result = monoify_module(ast, env.expr_type_index())
  let mut has_fold_list_inst = false
  for key, _ in result.instantiations {
    if key.has_prefix("Iterator::fold:List") {
      has_fold_list_inst = true
    }
  }
  assert_true(has_fold_list_inst)
  let mut has_fold_list = false
  let mut fold_calls_list_length = false
  let mut fold_calls_list_get = false
  let mut fold_param_specialized = false
  for stmt in result.ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        if name.has_prefix("Iterator::fold$List") {
          has_fold_list = true
          match expr {
            @core.Expr::Fn(params~, body~, ..) => {
              if params.length() >= 1 {
                fold_param_specialized = params[0].ty ==
                  @core.Type::Named(name="List", args=[@core.Type::Int])
              }
              fold_calls_list_length = monoify_module_has_call_prefix(
                body, "List::iter_length",
              )
              fold_calls_list_get = monoify_module_has_call_prefix(
                body, "List::iter_get",
              )
            }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(has_fold_list)
  assert_true(fold_param_specialized)
  assert_true(fold_calls_list_length)
  assert_true(fold_calls_list_get)
}

///|
test "monoify_module specializes root helper type params for iterator filter" {
  let ast = monoify_parse_and_desugar(
    "enum Trio[T] { Trio(T, T, T) }\n" +
    "impl [T] Iterable for Trio[T]\n" +
    "let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] { Trio(a, b, c) }\n" +
    "let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }\n" +
    "let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {\n" +
    "  match xs {\n" +
    "    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }\n" +
    "  }\n" +
    "}\n" +
    "let Iterator::filter = [C: Iterable, T](xs: C, pred: (x: T) -> Bool) -> Array[T] {\n" +
    "  let len = xs|>iter_length\n" +
    "  {\n" +
    "    let acc = ArrayBuilder::new()\n" +
    "    let mut i = 0\n" +
    "    while i < len {\n" +
    "      let value = xs|>iter_get(i)\n" +
    "      if pred(value) {\n" +
    "        ArrayBuilder::push(acc, value)\n" +
    "      }\n" +
    "      i = i + 1\n" +
    "    }\n" +
    "    ArrayBuilder::freeze(acc)\n" +
    "  }\n" +
    "}\n" +
    "let value = Iterator::filter(trio_of3(1, 2, 4), (x: Int) -> Bool { x % 2 == 0 })\n",
  )
  let env = type_check_for_monoify_test(ast)
  let result = monoify_module(ast, env.expr_type_index())
  let mut has_filter_inst = false
  let mut has_specialized_get = false
  let mut filter_calls_specialized_get = false
  for key, _ in result.instantiations {
    if key.has_prefix("Iterator::filter:Trio") {
      has_filter_inst = true
    }
  }
  for stmt in result.ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) => {
        if name.has_prefix("Trio::iter_get$Trio|T=Int") {
          has_specialized_get = true
        }
        if name.has_prefix("Iterator::filter$Trio|T=Int") {
          match expr {
            @core.Expr::Fn(body~, ..) =>
              filter_calls_specialized_get = monoify_module_has_call_prefix(
                body, "Trio::iter_get$Trio|T=Int",
              )
            _ => ()
          }
        }
      }
      _ => ()
    }
  }
  assert_true(has_filter_inst)
  assert_true(has_specialized_get)
  assert_true(filter_calls_specialized_get)
}

///|
test "monoify_module specializes callback return type for iterator flatmap" {
  let ast = monoify_parse_and_desugar(
    "enum Trio[T] { Trio(T, T, T) }\n" +
    "impl [T] Iterable for Trio[T]\n" +
    "let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] { Trio(a, b, c) }\n" +
    "let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }\n" +
    "let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {\n" +
    "  match xs {\n" +
    "    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }\n" +
    "  }\n" +
    "}\n" +
    "let Iterator::flatmap = [C: Iterable, A, B](xs: C, f: (x: A) -> Array[B]) -> Array[B] {\n" +
    "  let len = xs|>iter_length\n" +
    "  {\n" +
    "    let acc = ArrayBuilder::new()\n" +
    "    let mut i = 0\n" +
    "    while i < len {\n" +
    "      let chunk = f(xs|>iter_get(i))\n" +
    "      let chunk_len = Array::length(chunk)\n" +
    "      let mut j = 0\n" +
    "      while j < chunk_len {\n" +
    "        ArrayBuilder::push(acc, Array::get(chunk, j))\n" +
    "        j = j + 1\n" +
    "      }\n" +
    "      i = i + 1\n" +
    "    }\n" +
    "    ArrayBuilder::freeze(acc)\n" +
    "  }\n" +
    "}\n" +
    "let value = Iterator::flatmap(trio_of3(1, 2, 4), (x: Int) -> Array[Int] { [x, x + 1] })\n",
  )
  let env = type_check_for_monoify_test(ast)
  let result = monoify_module(ast, env.expr_type_index())
  let mut has_flatmap_inst = false
  let mut callback_ret_specialized = false
  let mut flatmap_calls_specialized_get = false
  for key, _ in result.instantiations {
    if key.has_prefix("Iterator::flatmap:Trio") {
      has_flatmap_inst = true
    }
  }
  for stmt in result.ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        if name.has_prefix("Iterator::flatmap$Trio") {
          match expr {
            @core.Expr::Fn(params~, body~, ..) =>
              if params.length() >= 2 {
                match params[1].ty {
                  @core.Type::Func(params=cb_params, ret~, ..) => {
                    if cb_params.length() >= 1 &&
                      cb_params[0].ty == @core.Type::Int {
                      match ret {
                        @core.Type::Array(@core.Type::Int) =>
                          callback_ret_specialized = true
                        @core.Type::Named(name="Array", args~) =>
                          if args.length() == 1 &&
                            args[0] == @core.Type::Named(name="Int", args=[]) {
                            callback_ret_specialized = true
                          }
                        _ => ()
                      }
                    }
                    flatmap_calls_specialized_get = monoify_module_has_call_prefix(
                      body, "Trio::iter_get$Trio|T=Int",
                    )
                  }
                  _ => ()
                }
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(has_flatmap_inst)
  assert_true(callback_ret_specialized)
  assert_true(flatmap_calls_specialized_get)
}
