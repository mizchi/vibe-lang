///|
pub fn dce_module(mod : @core.Module) -> @core.Module {
  @frontend.dce_module(mod)
}
