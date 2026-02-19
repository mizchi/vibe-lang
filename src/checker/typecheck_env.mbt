///|
pub struct TypecheckSession {
  next_type_var : Ref[Int]
  cached_prelude_env : Ref[TypeEnv?]
}

///|
pub fn TypecheckSession::new() -> TypecheckSession {
  { next_type_var: @ref.new(0), cached_prelude_env: @ref.new(None) }
}

///|
pub fn TypecheckSession::reset(self : TypecheckSession) -> Unit {
  self.next_type_var.val = 0
  self.cached_prelude_env.val = None
}

///|
let default_typecheck_session : TypecheckSession = TypecheckSession::new()

///|
pub struct TypeEnv {
  bindings : ScopedMap[TypeScheme]
  addr_types : Map[String, @core.Type]
  enum_defs : Map[String, EnumDef]
  struct_defs : Map[String, StructDef]
  type_aliases : Map[String, TypeAlias]
  ctor_index : Map[String, CtorInfo]
  traits : Map[String, TraitDefInfo]
  trait_impls : Map[String, Array[TraitImplDef]]
  fn_versions : Map[String, ApiSemver]
  purities : ScopedMap[Bool]
  expr_types : Map[Int64, @core.Type]
  num_vars : Map[Int, Bool]
  var_trait_bounds : Map[Int, Array[String]]
  mut next_var : Int
  mut next_effect_var : Int
  mut loop_depth : Int
  mut handle_arm_depth : Int
  mut handle_resume_types : Map[String, @core.Type]
  mut handle_resume_types_active : Bool
  mut handle_arm_effect_name : String?
  mut handle_arm_resume_expected : @core.Type?
  mut active_rec_fn : String?
  mut active_rec_fn_has_type_params : Bool
  subs : Map[Int, @core.Type]
  effect_subs : Map[String, Array[@core.EffectAtom]]
} derive(Show, Eq)

///|
pub fn TypeEnv::new() -> TypeEnv {
  {
    bindings: ScopedMap::new(),
    addr_types: {},
    enum_defs: {},
    struct_defs: {},
    type_aliases: {},
    ctor_index: {},
    traits: {},
    trait_impls: {},
    fn_versions: {},
    purities: ScopedMap::new(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    next_var: 0,
    next_effect_var: 0,
    loop_depth: 0,
    handle_arm_depth: 0,
    handle_resume_types: {},
    handle_resume_types_active: false,
    handle_arm_effect_name: None,
    handle_arm_resume_expected: None,
    active_rec_fn: None,
    active_rec_fn_has_type_params: false,
    subs: {},
    effect_subs: {},
  }
}
