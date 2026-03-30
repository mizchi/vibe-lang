///|
/// Helper: parse and eval a vibe source snippet, return the last value
fn eval_snippet(source : String) -> @core.Value raise {
  let ast = try @parser.parse_ast(source) catch {
    e => fail("parse error: " + e.to_string())
  } noraise {
    a => a
  }
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let result = try rt.eval_module(ast) catch {
    e => fail("eval error: " + e.to_string())
  } noraise {
    r => r
  }
  match result.last {
    Some(v) => v
    None => fail("no result value")
  }
}

///|
test "effect handler with continuation: basic sum" {
  // Emit(10) + Emit(20) + Emit(30) + 0 = 60
  let source =
    #|effect Emit {
    #|  Emit(Int) -> Unit
    #|}
    #|let count = handle {
    #|  perform Emit::Emit(10)
    #|  perform Emit::Emit(20)
    #|  perform Emit::Emit(30)
    #|  0
    #|} {
    #|  Emit::Emit(v, k) => v + k(0)
    #|}
    #|count
  let result = eval_snippet(source)
  assert_eq(result, @core.Value::Int(60L))
}

///|
test "effect handler with continuation: single perform" {
  let source =
    #|effect Ask {
    #|  Ask(Int) -> Int
    #|}
    #|handle {
    #|  perform Ask::Ask(10)
    #|} {
    #|  Ask::Ask(x, k) => x + 1
    #|}
  let result = eval_snippet(source)
  assert_eq(result, @core.Value::Int(11L))
}

///|
test "effect handler without continuation: legacy resume still works" {
  let source =
    #|enum Eff { Ask(Int) }
    #|handle {
    #|  perform(Ask(41))
    #|} {
    #|  Ask(_) => resume(42)
    #|}
  let result = eval_snippet(source)
  assert_eq(result, @core.Value::Int(42L))
}
