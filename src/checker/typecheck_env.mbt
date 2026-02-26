///|
pub struct SessionState {
  mut type_var_counter : Int
  mut lenient_mode : Bool
} derive(Show, Eq)

///|
pub struct TypecheckSession {
  state : SessionState
  cached_prelude_env : Ref[TypeEnv?]
  cached_builtins_env : Ref[TypeEnv?]
}

///|
pub fn TypecheckSession::new() -> TypecheckSession {
  {
    state: SessionState::{ type_var_counter: 0, lenient_mode: false },
    cached_prelude_env: @ref.new(None),
    cached_builtins_env: @ref.new(None),
  }
}

///|
pub fn TypecheckSession::reset(self : TypecheckSession) -> Unit {
  self.state.type_var_counter = 0
  self.state.lenient_mode = false
  self.cached_prelude_env.val = None
  self.cached_builtins_env.val = None
}

///|
let default_typecheck_session : TypecheckSession = TypecheckSession::new()

///|
pub(all) struct ScopedRefContainsCacheEntry {
  ty : @core.Type
  has_scoped_ref : Bool
} derive(Show, Eq)

///|
pub struct ScopedRefProfile {
  contains_calls : Int
  contains_cache_hits : Int
  contains_cache_misses : Int
  contains_time_us : Double
  capture_checks : Int
  capture_time_us : Double
  call_arg_checks : Int
  call_arg_time_us : Double
  return_checks : Int
  return_time_us : Double
  toplevel_checks : Int
  toplevel_time_us : Double
} derive(Show, Eq)

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
  purity_tiers : ScopedMap[TopLevelPurityTier]
  expr_types : Map[Int64, @core.Type]
  num_vars : Map[Int, Bool]
  var_trait_bounds : Map[Int, Array[String]]
  mut scoped_ref_contains_cache : Map[Int, Array[ScopedRefContainsCacheEntry]]
  mut scoped_ref_contains_cache_version : Int
  mut normalize_type_cache_expand : Map[Int, Array[(@core.Type, @core.Type)]]
  mut normalize_type_cache_preserve : Map[Int, Array[(@core.Type, @core.Type)]]
  mut normalize_type_cache_subs_version : Int
  mut scoped_ref_checks_enabled : Bool
  mut has_scoped_ref_binding : Bool
  mut scoped_ref_binding_scan_stale : Bool
  mut scoped_ref_profile_enabled : Bool
  mut scoped_ref_contains_calls : Int
  mut scoped_ref_contains_cache_hits : Int
  mut scoped_ref_contains_cache_misses : Int
  mut scoped_ref_contains_time_us : Double
  mut scoped_ref_capture_checks : Int
  mut scoped_ref_capture_time_us : Double
  mut scoped_ref_call_arg_checks : Int
  mut scoped_ref_call_arg_time_us : Double
  mut scoped_ref_return_checks : Int
  mut scoped_ref_return_time_us : Double
  mut scoped_ref_toplevel_checks : Int
  mut scoped_ref_toplevel_time_us : Double
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
  mut subs_version : Int
  subs : Map[Int, @core.Type]
  effect_subs : Map[String, Array[@core.EffectAtom]]
  session_state : SessionState
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
    purity_tiers: ScopedMap::new(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    scoped_ref_contains_cache: {},
    scoped_ref_contains_cache_version: 0,
    normalize_type_cache_expand: {},
    normalize_type_cache_preserve: {},
    normalize_type_cache_subs_version: 0,
    scoped_ref_checks_enabled: true,
    has_scoped_ref_binding: false,
    scoped_ref_binding_scan_stale: false,
    scoped_ref_profile_enabled: false,
    scoped_ref_contains_calls: 0,
    scoped_ref_contains_cache_hits: 0,
    scoped_ref_contains_cache_misses: 0,
    scoped_ref_contains_time_us: 0.0,
    scoped_ref_capture_checks: 0,
    scoped_ref_capture_time_us: 0.0,
    scoped_ref_call_arg_checks: 0,
    scoped_ref_call_arg_time_us: 0.0,
    scoped_ref_return_checks: 0,
    scoped_ref_return_time_us: 0.0,
    scoped_ref_toplevel_checks: 0,
    scoped_ref_toplevel_time_us: 0.0,
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
    subs_version: 0,
    subs: {},
    effect_subs: {},
    session_state: SessionState::{ type_var_counter: 0, lenient_mode: false },
  }
}

///|
pub fn TypecheckSession::new_env(self : TypecheckSession) -> TypeEnv {
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
    purity_tiers: ScopedMap::new(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    scoped_ref_contains_cache: {},
    scoped_ref_contains_cache_version: 0,
    normalize_type_cache_expand: {},
    normalize_type_cache_preserve: {},
    normalize_type_cache_subs_version: 0,
    scoped_ref_checks_enabled: true,
    has_scoped_ref_binding: false,
    scoped_ref_binding_scan_stale: false,
    scoped_ref_profile_enabled: false,
    scoped_ref_contains_calls: 0,
    scoped_ref_contains_cache_hits: 0,
    scoped_ref_contains_cache_misses: 0,
    scoped_ref_contains_time_us: 0.0,
    scoped_ref_capture_checks: 0,
    scoped_ref_capture_time_us: 0.0,
    scoped_ref_call_arg_checks: 0,
    scoped_ref_call_arg_time_us: 0.0,
    scoped_ref_return_checks: 0,
    scoped_ref_return_time_us: 0.0,
    scoped_ref_toplevel_checks: 0,
    scoped_ref_toplevel_time_us: 0.0,
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
    subs_version: 0,
    subs: {},
    effect_subs: {},
    session_state: self.state,
  }
}
