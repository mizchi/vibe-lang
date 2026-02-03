///| xsh test runner for `test {}` blocks

pub struct TestCase {
  name : String?
  body : Module
} derive(Show, Eq)

pub struct TestFailure {
  name : String?
  error : String
} derive(Show, Eq)

pub struct TestReport {
  total : Int
  passed : Int
  failed : Int
  failures : Array[TestFailure]
} derive(Show, Eq)

///| Collect top-level test blocks from a module.
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

///| Run all tests in a module. Test bodies execute in isolated envs.
pub fn Runtime::run_tests(self : Runtime, ast : Module) -> TestReport raise EvalError {
  let _ = self.eval_module(ast)
  let cases = collect_tests(ast)
  let failures : Array[TestFailure] = []
  let mut passed = 0
  for case in cases {
    let test_rt = self.fork_for_test()
    try {
      let _ = test_rt.eval_module(case.body)
      passed += 1
    } catch {
      e => failures.push(TestFailure::{ name: case.name, error: e.to_string() })
    }
  }
  let total = cases.length()
  { total, passed, failed: failures.length(), failures }
}
