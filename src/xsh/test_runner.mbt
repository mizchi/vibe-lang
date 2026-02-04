///|
/// xsh test runner for `test {}` blocks
pub struct TestCase {
  name : String?
  body : Module
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
pub fn collect_tests(ast : Module) -> Array[TestCase] {
  let out : Array[TestCase] = []
  for stmt in ast.stmts {
    match stmt {
      Stmt::Test(name~, body~) => out.push(TestCase::{ name, body })
      _ => ()
    }
  }
  out
}

///|
/// Run all tests in a module. Test bodies execute in isolated envs.
pub fn Runtime::run_tests(
  self : Runtime,
  ast : Module,
) -> TestReport raise EvalError {
  let _ = self.eval_module(ast)
  let cases = collect_tests(ast)
  let failures : Array[TestFailure] = []
  let mut passed = 0
  for case in cases {
    let cacheable = purity_block(self.type_env, case.body)
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
                None => Value::Unit
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
  let body_hash = expr_address(Expr::Block(body=case.body), {}, None)
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
fn collect_dep_names(body : Module) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  collect_dep_block(body, {}, out)
  out
}

///|
fn collect_dep_block(
  body : Module,
  bound : Map[String, Bool],
  out : Map[String, Bool],
) -> Unit {
  let scope = clone_bool_map(bound)
  for stmt in body.stmts {
    match stmt {
      Stmt::Let(rec~, name~, expr~) => {
        if rec {
          scope[name] = true
        }
        collect_dep_expr(expr, scope, out)
        if not(rec) {
          scope[name] = true
        }
      }
      Stmt::Expr(expr~) => collect_dep_expr(expr, scope, out)
      Stmt::Test(..) => ()
      _ => ()
    }
  }
}

///|
fn collect_dep_expr(
  expr : Expr,
  bound : Map[String, Bool],
  out : Map[String, Bool],
) -> Unit {
  match expr {
    Expr::Int(_) => ()
    Expr::Bool(_) => ()
    Expr::String(_) => ()
    Expr::Ident(name) => add_dep_name(name, bound, out)
    Expr::Call(name~, args~) => {
      add_dep_name(name, bound, out)
      for arg in args {
        collect_dep_expr(arg.expr, bound, out)
      }
    }
    Expr::Tuple(items) =>
      for item in items {
        collect_dep_expr(item, bound, out)
      }
    Expr::Record(fields) =>
      for field in fields {
        collect_dep_expr(field.expr, bound, out)
      }
    Expr::Array(items) =>
      for item in items {
        collect_dep_expr(item, bound, out)
      }
    Expr::Map(fields) =>
      for field in fields {
        collect_dep_expr(field.expr, bound, out)
      }
    Expr::If(cond~, then_body~, else_body~) => {
      collect_dep_expr(cond, bound, out)
      collect_dep_block(then_body, bound, out)
      collect_dep_block(else_body, bound, out)
    }
    Expr::Block(body~) => collect_dep_block(body, bound, out)
    Expr::Do(body~) => collect_dep_block(body, bound, out)
    Expr::Match(scrutinee~, arms~) => {
      collect_dep_expr(scrutinee, bound, out)
      for arm in arms {
        let arm_bound = clone_bool_map(bound)
        bind_pattern_names(arm_bound, arm.pat)
        match arm.cond {
          Some(cond) => collect_dep_expr(cond, arm_bound, out)
          None => ()
        }
        collect_dep_expr(arm.expr, arm_bound, out)
      }
    }
    Expr::Fn(params~, ret~, body~) => {
      let _ = ret
      let fn_bound = clone_bool_map(bound)
      for param in params {
        fn_bound[param.name] = true
      }
      collect_dep_block(body, fn_bound, out)
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
  if is_builtin_name(name) || is_ctor_name(name) || has_qualified_name(name) {
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
  name == "array_builder" ||
  name == "array_builder_push" ||
  name == "array_builder_freeze" ||
  name == "map_builder" ||
  name == "map_builder_set" ||
  name == "map_builder_freeze"
}
