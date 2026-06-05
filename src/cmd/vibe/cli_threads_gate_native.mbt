///|
fn source_uses_threads_builtins(source : String) -> Result[Bool, String] {
  let raw_ast = @parser.parse_ast(source) catch {
    e => return Err(e.to_string())
  }
  let desugared = @frontend.desugar_method_calls(raw_ast, {})
  let ast = @frontend.rewrite_effect_handles(desugared)
  Ok(module_uses_threads_builtins(ast))
}
