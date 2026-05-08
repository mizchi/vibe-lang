///|
pub struct SessionState {
  mut type_var_counter : Int
  mut lenient_mode : Bool
  mut skip_fn_body_check : Bool
} derive(Debug, Eq)

///|
pub struct TypecheckSession {
  state : SessionState
  cached_prelude_env : Ref[TypeEnv?]
  cached_builtins_env : Ref[TypeEnv?]
}

///|
pub fn TypecheckSession::new() -> TypecheckSession {
  {
    state: SessionState::{
      type_var_counter: 0,
      lenient_mode: false,
      skip_fn_body_check: false,
    },
    cached_prelude_env: @ref.new(None),
    cached_builtins_env: @ref.new(None),
  }
}

///|
pub fn TypecheckSession::reset(self : TypecheckSession) -> Unit {
  self.state.type_var_counter = 0
  self.state.lenient_mode = false
  self.state.skip_fn_body_check = false
  self.cached_prelude_env.val = None
  self.cached_builtins_env.val = None
}

///|
let default_typecheck_session : TypecheckSession = TypecheckSession::new()

///|
pub(all) struct ScopedRefContainsCacheEntry {
  ty : @core.Type
  has_scoped_ref : Bool
} derive(Debug, Eq)

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
} derive(Debug, Eq)

///|
pub struct TypeEnv {
  bindings : @scoped_map.ScopedMap[TypeScheme]
  addr_types : Map[String, @core.Type]
  enum_defs : Map[String, EnumDef]
  struct_defs : Map[String, StructDef]
  type_aliases : Map[String, TypeAlias]
  ctor_index : Map[String, CtorInfo]
  effect_defs : Map[String, @core.EffectDef_]
  // Inferred effects: collected when perform is used without explicit with { }
  inferred_effects : Map[String, Bool]
  trait_state : TraitState
  fn_versions : Map[String, ApiSemver]
  purities : @scoped_map.ScopedMap[Bool]
  purity_tiers : @scoped_map.ScopedMap[TopLevelPurityTier]
  expr_types : Map[Int64, @core.Type]
  num_vars : Map[Int, Bool]
  var_trait_bounds : Map[Int, Array[String]]
  mut scoped_ref_contains_cache : Map[
    String,
    Array[ScopedRefContainsCacheEntry],
  ]
  mut scoped_ref_contains_cache_version : Int
  mut normalize_type_cache_expand : Map[String, Array[(@core.Type, @core.Type)]]
  mut normalize_type_cache_preserve : Map[
    String,
    Array[(@core.Type, @core.Type)],
  ]
  mut normalize_type_cache_subs_version : Int
  // Ground caches for 0-arg Named types.  These are NOT invalidated by
  // subs_version changes because the normalization of a 0-arg Named type
  // depends only on type definitions, not on type variable substitutions.
  // Cleared only when type definitions change (set_enum_def, set_struct, set_type_alias).
  mut normalize_type_cache_expand_ground : Map[String, @core.Type]
  mut normalize_type_cache_preserve_ground : Map[String, @core.Type]
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
  mut loop_break_types : Array[@core.Type]
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
} derive(Debug, Eq)

///|
pub fn TypeEnv::new() -> TypeEnv {
  let env : TypeEnv = {
    bindings: @scoped_map.ScopedMap::new(),
    addr_types: {},
    enum_defs: {},
    struct_defs: {},
    type_aliases: {},
    ctor_index: {},
    effect_defs: {},
    inferred_effects: {},
    trait_state: TraitState::new(),
    fn_versions: {},
    purities: @scoped_map.ScopedMap::new(),
    purity_tiers: @scoped_map.ScopedMap::new(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    scoped_ref_contains_cache: {},
    scoped_ref_contains_cache_version: 0,
    normalize_type_cache_expand: {},
    normalize_type_cache_preserve: {},
    normalize_type_cache_subs_version: 0,
    normalize_type_cache_expand_ground: {},
    normalize_type_cache_preserve_ground: {},
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
    loop_break_types: [],
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
    session_state: SessionState::{
      type_var_counter: 0,
      lenient_mode: false,
      skip_fn_body_check: false,
    },
  }
  register_builtin_effects(env)
  env
}

///|
/// Register built-in effects (Error, Fs, Net aliases) in the environment.
fn register_builtin_effects(env : TypeEnv) -> Unit {
  // Error effect
  let error_ops : Map[String, @core.EffectOpSig] = {}
  // Accept any type that implements the Error trait (String, suberror, etc.)
  error_ops["Throw"] = @core.EffectOpSig::{
    params: [@core.Type::Param("E")],
    ret: @core.Type::Never,
  }
  env.effect_defs["Error"] = @core.EffectDef_::{
    name: "Error",
    params: ["E"],
    ops: error_ops,
  }
  // Fs effect (maps to builtin Fs::* calls)
  let fs_ops : Map[String, @core.EffectOpSig] = {}
  fs_ops["ReadFile"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::String,
  }
  fs_ops["WriteFile"] = @core.EffectOpSig::{
    params: [@core.Type::String, @core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["Exists"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Bool,
  }
  fs_ops["Mkdir"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["MkdirP"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["Remove"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["Copy"] = @core.EffectOpSig::{
    params: [@core.Type::String, @core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["Rename"] = @core.EffectOpSig::{
    params: [@core.Type::String, @core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["ReadDir"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Array(@core.Type::String),
  }
  fs_ops["IsDir"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Bool,
  }
  fs_ops["IsFile"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Bool,
  }
  fs_ops["Getcwd"] = @core.EffectOpSig::{ params: [], ret: @core.Type::String }
  fs_ops["Chdir"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Unit,
  }
  fs_ops["Append"] = @core.EffectOpSig::{
    params: [@core.Type::String, @core.Type::String],
    ret: @core.Type::Unit,
  }
  env.effect_defs["Fs"] = @core.EffectDef_::{
    name: "Fs",
    params: [],
    ops: fs_ops,
  }
  // Http effect (requires with { Net } or with { Http })
  let http_ops : Map[String, @core.EffectOpSig] = {}
  for
    pair in [
      ("Listen", ([@core.Type::Int], @core.Type::Int)),
      ("Accept", ([@core.Type::Int], @core.Type::Int)),
      ("Close", ([@core.Type::Int], @core.Type::Unit)),
      ("RequestMethod", ([@core.Type::Int], @core.Type::String)),
      ("RequestUrl", ([@core.Type::Int], @core.Type::String)),
      (
        "RequestHeader",
        ([@core.Type::Int, @core.Type::String], @core.Type::String),
      ),
      ("RequestBody", ([@core.Type::Int], @core.Type::String)),
      ("ResponseStatus", ([@core.Type::Int], @core.Type::Int)),
      (
        "ResponseHeader",
        ([@core.Type::Int, @core.Type::String], @core.Type::String),
      ),
      ("ResponseBody", ([@core.Type::Int], @core.Type::String)),
    ] {
    let (name, (params, ret)) = pair
    http_ops[name] = @core.EffectOpSig::{ params, ret }
  }
  http_ops["Request"] = @core.EffectOpSig::{
    params: [
      @core.Type::String,
      @core.Type::String,
      @core.Type::String,
      @core.Type::String,
    ],
    ret: @core.Type::Int,
  }
  http_ops["Respond"] = @core.EffectOpSig::{
    params: [
      @core.Type::Int,
      @core.Type::Int,
      @core.Type::String,
      @core.Type::String,
    ],
    ret: @core.Type::Unit,
  }
  env.effect_defs["Http"] = @core.EffectDef_::{
    name: "Http",
    params: [],
    ops: http_ops,
  }
  // Socket effect (requires with { Net } or with { Socket })
  let socket_ops : Map[String, @core.EffectOpSig] = {}
  socket_ops["Connect"] = @core.EffectOpSig::{
    params: [@core.Type::String, @core.Type::Int],
    ret: @core.Type::Int,
  }
  socket_ops["Read"] = @core.EffectOpSig::{
    params: [@core.Type::Int, @core.Type::Int],
    ret: @core.Type::String,
  }
  socket_ops["Write"] = @core.EffectOpSig::{
    params: [@core.Type::Int, @core.Type::String],
    ret: @core.Type::Unit,
  }
  socket_ops["Close"] = @core.EffectOpSig::{
    params: [@core.Type::Int],
    ret: @core.Type::Unit,
  }
  env.effect_defs["Socket"] = @core.EffectDef_::{
    name: "Socket",
    params: [],
    ops: socket_ops,
  }
  // Process effect
  let proc_ops : Map[String, @core.EffectOpSig] = {}
  proc_ops["Exec"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::String,
  }
  env.effect_defs["Process"] = @core.EffectDef_::{
    name: "Process",
    params: [],
    ops: proc_ops,
  }
  // Env effect
  let env_ops : Map[String, @core.EffectOpSig] = {}
  env_ops["Get"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::String,
  }
  env_ops["ArgsLen"] = @core.EffectOpSig::{ params: [], ret: @core.Type::Int }
  env_ops["ArgsGet"] = @core.EffectOpSig::{
    params: [@core.Type::Int],
    ret: @core.Type::String,
  }
  env.effect_defs["Env"] = @core.EffectDef_::{
    name: "Env",
    params: [],
    ops: env_ops,
  }
  // Stdout effect
  let stdout_ops : Map[String, @core.EffectOpSig] = {}
  stdout_ops["WriteChar"] = @core.EffectOpSig::{
    params: [@core.Type::Int],
    ret: @core.Type::Unit,
  }
  stdout_ops["WriteStream"] = @core.EffectOpSig::{
    params: [@core.Type::String],
    ret: @core.Type::Unit,
  }
  env.effect_defs["Stdout"] = @core.EffectDef_::{
    name: "Stdout",
    params: [],
    ops: stdout_ops,
  }
  // Stdin effect
  let stdin_ops : Map[String, @core.EffectOpSig] = {}
  stdin_ops["ReadChar"] = @core.EffectOpSig::{
    params: [],
    ret: @core.Type::Int,
  }
  stdin_ops["ReadStream"] = @core.EffectOpSig::{
    params: [@core.Type::Int],
    ret: @core.Type::String,
  }
  env.effect_defs["Stdin"] = @core.EffectDef_::{
    name: "Stdin",
    params: [],
    ops: stdin_ops,
  }
}

///|
pub fn TypecheckSession::new_env(self : TypecheckSession) -> TypeEnv {
  let env : TypeEnv = {
    bindings: @scoped_map.ScopedMap::new(),
    addr_types: {},
    enum_defs: {},
    struct_defs: {},
    type_aliases: {},
    ctor_index: {},
    effect_defs: {},
    inferred_effects: {},
    trait_state: TraitState::new(),
    fn_versions: {},
    purities: @scoped_map.ScopedMap::new(),
    purity_tiers: @scoped_map.ScopedMap::new(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    scoped_ref_contains_cache: {},
    scoped_ref_contains_cache_version: 0,
    normalize_type_cache_expand: {},
    normalize_type_cache_preserve: {},
    normalize_type_cache_subs_version: 0,
    normalize_type_cache_expand_ground: {},
    normalize_type_cache_preserve_ground: {},
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
    loop_break_types: [],
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
  register_builtin_effects(env)
  env
}
