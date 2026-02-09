///|
pub type MonoifyResult = @frontend.MonoifyResult

///|
pub fn monoify_module(
  ast : @core.Module,
  env : @checker.TypeEnv,
) -> MonoifyResult {
  @frontend.monoify_module(ast, env)
}
