///|
pub struct CtorInfo {
  type_name : String
  params : Array[String]
  payload : @core.Type
} derive(Debug, Eq)

///|
priv struct CtorInstance {
  payload : @core.Type
  ret : @core.Type
}

///|
pub struct EnumDef {
  name : String
  params : Array[String]
  ctors : Array[@core.TypeCtor]
} derive(Debug, Eq)

///|
pub struct TypeAlias {
  name : String
  params : Array[String]
  target : @core.Type
} derive(Debug, Eq)

///|
pub struct StructFieldDef {
  name : String
  ty : @core.Type
  // ADR-0052: `mut name: T` — direct field assignment `r.name = e` is
  // allowed only when this flag is true.
  is_mut : Bool
} derive(Debug, Eq)

///|
pub struct StructDef {
  name : String
  params : Array[String]
  fields : Array[StructFieldDef]
} derive(Debug, Eq)

///|
pub fn StructDef::get_field(self : StructDef, name : String) -> StructFieldDef? {
  for field in self.fields {
    if field.name == name {
      return Some(field)
    }
  }
  None
}

///|
pub fn TypeEnv::get_enum_def(self : TypeEnv, name : String) -> EnumDef? {
  self.enum_defs.get(name)
}

///|
pub fn TypeEnv::enum_names(self : TypeEnv) -> Array[String] {
  let out : Array[String] = []
  for name, _ in self.enum_defs {
    out.push(name)
  }
  out
}

///|
pub fn TypeEnv::set_enum_def(
  self : TypeEnv,
  name : String,
  def : EnumDef,
) -> Unit {
  self.enum_defs[name] = def
  self.invalidate_scoped_ref_contains_cache()
  self.invalidate_normalize_type_cache()
}

///|
pub fn TypeEnv::get_struct(self : TypeEnv, name : String) -> StructDef? {
  self.struct_defs.get(name)
}

///|
pub fn TypeEnv::set_struct(
  self : TypeEnv,
  name : String,
  def : StructDef,
) -> Unit {
  self.struct_defs[name] = def
  self.invalidate_scoped_ref_contains_cache()
  self.invalidate_normalize_type_cache()
}

///|
pub fn TypeEnv::get_type_alias(self : TypeEnv, name : String) -> TypeAlias? {
  self.type_aliases.get(name)
}

///|
pub fn TypeEnv::set_type_alias(
  self : TypeEnv,
  name : String,
  type_alias : TypeAlias,
) -> Unit {
  self.type_aliases[name] = type_alias
  self.invalidate_scoped_ref_contains_cache()
  self.invalidate_normalize_type_cache()
}

///|
pub fn TypeEnv::get_ctor(self : TypeEnv, name : String) -> CtorInfo? {
  self.ctor_index.get(name)
}

///|
pub fn TypeEnv::set_ctor(
  self : TypeEnv,
  name : String,
  info : CtorInfo,
) -> Unit {
  self.ctor_index[name] = info
}
