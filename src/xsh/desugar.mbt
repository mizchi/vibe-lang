///|
pub fn desugar_method_calls(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> @core.Module {
  @frontend.desugar_method_calls(ast, aliases)
}

///|
pub fn desugar_xshell_commands(ast : @core.Module) -> @core.Module {
  @frontend.desugar_xshell_commands(ast)
}
