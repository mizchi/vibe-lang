///|
pub fn TypeEnv::variant_namespace_root(
  self : TypeEnv,
  fields : Map[String, @core.Type],
) -> String? {
  let mut found : String? = None
  for enum_name in self.enum_names() {
    match self.get_enum_def(enum_name) {
      Some(enum_def) => {
        if enum_def.ctors.length() != fields.length() {
          continue
        }
        let mut all_match = true
        for ctor in enum_def.ctors {
          if not(fields.contains(ctor.name)) {
            all_match = false
            break
          }
        }
        if all_match {
          match found {
            None => found = Some(enum_name)
            Some(_) => return None
          }
        }
      }
      None => ()
    }
  }
  found
}

///|
/// Resolve namespace root from an already-resolved type (no type variable substitution).
/// Used by both checker and runtime for type member dispatch.
pub fn TypeEnv::namespace_root(self : TypeEnv, ty : @core.Type) -> String? {
  match ty {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::Char => Some("Char")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::PromptText => Some("PromptText")
    @core.Type::Named(name~, ..) => Some(name)
    @core.Type::Variant(fields) => self.variant_namespace_root(fields)
    _ => None
  }
}

///|
fn namespace_root_from_type(env : TypeEnv, ty : @core.Type) -> String? {
  env.namespace_root(resolve_type(env, ty))
}
