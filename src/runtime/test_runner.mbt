///|
/// vibe test runner for `test {}` blocks
struct TestCase {
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
fn collect_tests(ast : @core.Module) -> Array[TestCase] {
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
        // Test executions must not inherit stale resume overrides from parent runtime.
        test_rt.clear_perform_resume_overrides()
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
  @core.walk_block_refs(body, @core.WalkerScope::new(), out, add_dep_name)
  out
}

///|
fn add_dep_name(
  name : String,
  bound : @core.WalkerScope,
  out : Map[String, Bool],
) -> Unit {
  if bound.contains(name) {
    return
  }
  if @core.is_builtin_name(name) ||
    @core.is_logic_builtin_name(name) ||
    @core.is_ctor_name(name) ||
    @core.has_qualified_name(name) {
    return
  }
  out[name] = true
}
