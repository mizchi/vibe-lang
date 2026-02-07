///|
/// xsh test runner for `test {}` blocks
pub struct TestCase {
  name : String?
  body : @core.Module
} derive(Show, Eq)

///|
pub struct TestFailure {
  name : String?
  error : String
} derive(Show, Eq)

///|
pub struct TestReport {
  total : Int
  passed : Int
  failed : Int
  failures : Array[TestFailure]
} derive(Show, Eq)

///|
/// Collect top-level test blocks from a module.
pub fn collect_tests(ast : @core.Module) -> Array[TestCase] {
  let out : Array[TestCase] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        out.push(TestCase::{ name, body })
      }
      _ => ()
    }
  }
  out
}

///|
/// Run all tests in a module. Test bodies execute in isolated envs.
pub fn Runtime::run_tests(
  self : Runtime,
  ast : @core.Module,
) -> TestReport raise EvalError {
  let _ = self.eval_module(ast)
  let cases = collect_tests(ast)
  let failures : Array[TestFailure] = []
  let mut passed = 0
  for case in cases {
    let cacheable = @checker.purity_block(self.type_env, case.body)
    let key = test_case_key(case)
    let deps = if cacheable { Some(collect_dep_names(case.body)) } else { None }
    let dep_addrs = match deps {
      Some(dep_names) => resolve_dep_addrs(self, dep_names)
      None => None
    }
    let mut cached : TestOutcome? = None
    match dep_addrs {
      Some(dep_snapshot) =>
        match self.test_cache.get(key) {
          Some(entry) =>
            if deps_equal(entry.deps, dep_snapshot) {
              cached = Some(entry.outcome)
            }
          None => ()
        }
      None => ()
    }
    match cached {
      Some(outcome) =>
        match outcome {
          TestOutcome::Passed(_) => passed += 1
          TestOutcome::Failed(err) =>
            failures.push(TestFailure::{ name: case.name, error: err })
        }
      None => {
        let test_rt = self.fork_for_test()
        try {
          let res = test_rt.eval_module(case.body)
          passed += 1
          match dep_addrs {
            Some(dep_snapshot) => {
              let last = match res.last {
                Some(v) => v
                None => @core.Value::Unit
              }
              let entry = TestCacheEntry::{
                deps: dep_snapshot,
                outcome: TestOutcome::Passed(last),
              }
              self.test_cache.set(key, entry)
            }
            None => ()
          }
        } catch {
          e => {
            failures.push(TestFailure::{ name: case.name, error: e.to_string() })
            match dep_addrs {
              Some(dep_snapshot) => {
                let entry = TestCacheEntry::{
                  deps: dep_snapshot,
                  outcome: TestOutcome::Failed(e.to_string()),
                }
                self.test_cache.set(key, entry)
              }
              None => ()
            }
          }
        }
      }
    }
  }
  let total = cases.length()
  { total, passed, failed: failures.length(), failures }
}

///|
fn test_case_key(case : TestCase) -> String {
  let name = match case.name {
    Some(n) => n
    None => ""
  }
  let body_hash = @codegen.expr_address(
    @core.Expr::Block(body=case.body, span=@core.Span::empty(0)),
    {},
    None,
  )
  "test:" + name + ":" + body_hash
}

///|
fn resolve_dep_addrs(
  rt : Runtime,
  deps : Map[String, Bool],
) -> Map[String, String]? {
  let out : Map[String, String] = {}
  for name, _ in deps {
    match rt.get_addr(name) {
      Some(addr) => out[name] = addr
      None =>
        match rt.get_name_alias(name) {
          Some(addr) => out[name] = addr
          None => return None
        }
    }
  }
  Some(out)
}

///|
fn deps_equal(a : Map[String, String], b : Map[String, String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut ok = true
  for name, addr in a {
    match b.get(name) {
      Some(other) =>
        if addr != other {
          ok = false
          break
        }
      None => {
        ok = false
        break
      }
    }
  }
  ok
}

///|
fn collect_dep_names(body : @core.Module) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  collect_dep_block(body, {}, out)
  out
}

///|
fn collect_dep_block(
  body : @core.Module,
  bound : Map[String, Bool],
  out : Map[String, Bool],
) -> Unit {
  let scope = @checker.clone_bool_map(bound)
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        collect_dep_expr(expr, scope, out)
        if not(rec) {
          scope[name] = true
        }
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_dep_expr(expr, scope, out)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span

      }
      _ => ()
    }
  }
}

///|
fn collect_dep_expr(
  expr : @core.Expr,
  bound : Map[String, Bool],
  out : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      add_dep_name(name, bound, out)
    }
    @core.Expr::Placeholder(..) => ()
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      add_dep_name(name, bound, out)
      for arg in args {
        collect_dep_expr(arg.expr, bound, out)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_dep_expr(item, bound, out)
      }
    }
    @core.Expr::TupleIndex(expr~, ..) => collect_dep_expr(expr, bound, out)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_dep_expr(field.expr, bound, out)
      }
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let _ = span
      let _ = type_args
      add_dep_name(name, bound, out)
      for field in fields {
        collect_dep_expr(field.expr, bound, out)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_dep_expr(item, bound, out)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_dep_expr(field.expr, bound, out)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_dep_expr(cond, bound, out)
      collect_dep_block(then_body, bound, out)
      collect_dep_block(else_body, bound, out)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_dep_block(body, bound, out)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      collect_dep_block(body, bound, out)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      collect_dep_block(try_body, bound, out)
      collect_dep_block(catch_body, bound, out)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_dep_expr(scrutinee, bound, out)
      for arm in arms {
        let arm_bound = @checker.clone_bool_map(bound)
        @checker.bind_pattern_names(arm_bound, arm.pat)
        match arm.cond {
          Some(cond) => collect_dep_expr(cond, arm_bound, out)
          None => ()
        }
        collect_dep_expr(arm.expr, arm_bound, out)
      }
    }
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_bound = @checker.clone_bool_map(bound)
      for param in params {
        fn_bound[param.name] = true
      }
      collect_dep_block(body, fn_bound, out)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      collect_dep_expr(cond, bound, out)
      collect_dep_block(body, bound, out)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      collect_dep_expr(value, bound, out)
    }
    @core.Expr::Await(expr~, span~) => {
      let _ = span
      collect_dep_expr(expr, bound, out)
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      collect_dep_expr(expr, bound, out)
    }
  }
}

///|
fn add_dep_name(
  name : String,
  bound : Map[String, Bool],
  out : Map[String, Bool],
) -> Unit {
  if bound.contains(name) {
    return
  }
  if is_builtin_name(name) ||
    @core.is_ctor_name(name) ||
    has_qualified_name(name) {
    return
  }
  out[name] = true
}

///|
fn has_qualified_name(name : String) -> Bool {
  let chars = name.to_array()
  for c in chars {
    if c == '.' {
      return true
    }
  }
  false
}

///|
fn is_builtin_name(name : String) -> Bool {
  name == "path" ||
  name == "addr" ||
  name == "sh" ||
  name == "add" ||
  name == "sub" ||
  name == "mul" ||
  name == "div" ||
  name == "eq" ||
  name == "lt" ||
  name == "not" ||
  name == "and" ||
  name == "or" ||
  name == "stdout_write_char" ||
  name == "stdout_write_stream" ||
  name == "stdin_read_char" ||
  name == "stdin_read_stream" ||
  name == "array_builder" ||
  name == "array_builder_push" ||
  name == "array_builder_freeze" ||
  name == "map_builder" ||
  name == "map_builder_set" ||
  name == "map_builder_freeze"
}
