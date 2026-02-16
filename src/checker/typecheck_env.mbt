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
pub struct CtorInfo {
  type_name : String
  params : Array[String]
  payload : @core.Type
} derive(Show, Eq)

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
} derive(Show, Eq)

///|
pub struct TypeScheme {
  vars : Array[Int]
  num_vars : Array[Int]
  effect_vars : Array[String]
  trait_bounds : Map[Int, Array[String]]
  ty : @core.Type
} derive(Show, Eq)

///|
pub struct ApiSemver {
  major : Int
  minor : Int
  patch : Int
} derive(Show, Eq)

///|
pub struct TraitImplDef {
  type_params : Array[String]
  type_bounds : Map[String, Array[String]]
  target : @core.Type
} derive(Show, Eq)

///|
pub struct TraitDefInfo {
  supertraits : Array[String]
  open_impl : Bool
  is_local : Bool
} derive(Show, Eq)

///|
pub struct TypeAlias {
  name : String
  params : Array[String]
  target : @core.Type
} derive(Show, Eq)

///|
pub struct StructFieldDef {
  name : String
  ty : @core.Type
} derive(Show, Eq)

///|
pub struct StructDef {
  name : String
  params : Array[String]
  fields : Array[StructFieldDef]
} derive(Show, Eq)

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
pub struct TypeEnv {
  bindings : Map[String, TypeScheme]
  addr_types : Map[String, @core.Type]
  enum_defs : Map[String, EnumDef]
  struct_defs : Map[String, StructDef]
  type_aliases : Map[String, TypeAlias]
  ctor_index : Map[String, CtorInfo]
  traits : Map[String, TraitDefInfo]
  trait_impls : Map[String, Array[TraitImplDef]]
  fn_versions : Map[String, ApiSemver]
  purities : Map[String, Bool]
  expr_types : Map[Int64, @core.Type]
  num_vars : Map[Int, Bool]
  var_trait_bounds : Map[Int, Array[String]]
  mut next_var : Int
  mut next_effect_var : Int
  mut loop_depth : Int
  mut active_rec_fn : String?
  mut active_rec_fn_has_type_params : Bool
  subs : Map[Int, @core.Type]
  effect_subs : Map[String, Array[@core.EffectAtom]]
} derive(Show, Eq)

///|
priv struct EffectSet {
  consts : Map[String, Bool]
  rest : String?
}

///|
priv struct EffectScope {
  allow_all : Bool
  allowed : Map[String, Bool]
  rest : String?
}

///|
fn effect_scope_all() -> EffectScope {
  EffectScope::{ allow_all: true, allowed: {}, rest: None }
}

///|
fn effect_scope_from_list(effects : Array[@core.EffectAtom]) -> EffectScope {
  let allowed : Map[String, Bool] = {}
  let mut rest : String? = None
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(name) => allowed[name] = true
      @core.EffectAtom::Var(name) =>
        match rest {
          Some(existing) => if existing != name { () }
          None => rest = Some(name)
        }
    }
  }
  EffectScope::{ allow_all: false, allowed, rest }
}

///|
fn normalize_effects(
  effects : Array[@core.EffectAtom],
  span : @core.Span,
) -> Array[@core.EffectAtom] raise TypeError {
  let out : Array[@core.EffectAtom] = []
  let seen : Map[String, Bool] = {}
  let mut seen_var : String? = None
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(name) =>
        if not(seen.contains(name)) {
          seen[name] = true
          out.push(effect)
        }
      @core.EffectAtom::Var(name) =>
        match seen_var {
          Some(existing) =>
            if existing != name {
              raise TypeError::BadTypeDef(message="multiple effect vars", span~)
            } else {
              ()
            }
          None => {
            seen_var = Some(name)
            out.push(effect)
          }
        }
    }
  }
  out
}

///|
fn require_effects(
  env : TypeEnv,
  scope : EffectScope,
  effects : Array[@core.EffectAtom],
  operation : String,
  span : @core.Span,
) -> Unit raise TypeError {
  match find_missing_effect(env, scope, effects) {
    Some(name) =>
      raise TypeError::EffectGuardNotSatisfied(
        operation~,
        missing_effect=Some(name),
        missing_do_boundary=false,
        span~,
      )
    None => ()
  }
}

///|
fn find_missing_effect(
  env : TypeEnv,
  scope : EffectScope,
  effects : Array[@core.EffectAtom],
) -> String? raise TypeError {
  if scope.allow_all {
    return None
  }
  let scope_set = effect_set_from_scope(scope)
  let required_set = effect_set_from_atoms(env, effects)
  ensure_effects_allowed(env, scope_set, required_set)
}

///|
fn require_effect_guard(
  env : TypeEnv,
  scope : EffectScope,
  allow_effect : Bool,
  operation : String,
  required_effects : Array[@core.EffectAtom],
  span : @core.Span,
) -> Unit raise TypeError {
  let missing_effect = find_missing_effect(env, scope, required_effects)
  let missing_do_boundary = is_do_boundary_operation(operation) &&
    not(allow_effect)
  if missing_effect == None && not(missing_do_boundary) {
    ()
  } else {
    raise TypeError::EffectGuardNotSatisfied(
      operation~,
      missing_effect~,
      missing_do_boundary~,
      span~,
    )
  }
}

///|
fn builtin_effects(name : String) -> Array[@core.EffectAtom] {
  match name {
    "sh" => [@core.EffectAtom::Const("Stdout")]
    "sh_lines" => [@core.EffectAtom::Const("Stdout")]
    "stdout_write_char" => [@core.EffectAtom::Const("Stdout")]
    "stdout_write_stream" => [@core.EffectAtom::Const("Stdout")]
    "stdin_read_char" => [@core.EffectAtom::Const("Stdin")]
    "stdin_read_stream" => [@core.EffectAtom::Const("Stdin")]
    "sleep" => [@core.EffectAtom::Const("Async")]
    "dynamic_path_resolve" => [@core.EffectAtom::Const("Env")]
    "fs_read_file" | "fs_write_file" | "fs_exists" =>
      [@core.EffectAtom::Const("Fs")]
    "socket_tcp_connect"
    | "socket_tcp_read"
    | "socket_tcp_write"
    | "socket_tcp_close" => [@core.EffectAtom::Const("Net")]
    "http_request"
    | "http_response_status"
    | "http_response_header"
    | "http_response_body"
    | "http_close"
    | "http_listen"
    | "http_accept"
    | "http_request_method"
    | "http_request_url"
    | "http_request_header"
    | "http_request_body"
    | "http_respond" => [@core.EffectAtom::Const("Net")]
    _ => []
  }
}

///|
fn effect_scope_extend(
  scope : EffectScope,
  extra : Array[@core.EffectAtom],
) -> EffectScope {
  if scope.allow_all {
    scope
  } else {
    let allowed : Map[String, Bool] = {}
    let mut rest = scope.rest
    for key, val in scope.allowed {
      allowed[key] = val
    }
    for effect in extra {
      match effect {
        @core.EffectAtom::Const(name) => allowed[name] = true
        @core.EffectAtom::Var(name) =>
          match rest {
            Some(existing) => if existing != name { () }
            None => rest = Some(name)
          }
      }
    }
    EffectScope::{ allow_all: false, allowed, rest }
  }
}

///|
fn effect_set_empty() -> EffectSet {
  EffectSet::{ consts: {}, rest: None }
}

///|
fn effect_set_from_scope(scope : EffectScope) -> EffectSet {
  let consts : Map[String, Bool] = {}
  for key, val in scope.allowed {
    consts[key] = val
  }
  EffectSet::{ consts, rest: scope.rest }
}

///|
fn effect_set_merge(a : EffectSet, b : EffectSet) -> EffectSet raise TypeError {
  let consts : Map[String, Bool] = {}
  for key, val in a.consts {
    consts[key] = val
  }
  for key, val in b.consts {
    consts[key] = val
  }
  let rest = match (a.rest, b.rest) {
    (None, None) => None
    (Some(v), None) => Some(v)
    (None, Some(v)) => Some(v)
    (Some(v1), Some(v2)) =>
      if v1 == v2 {
        Some(v1)
      } else {
        raise TypeError::BadTypeDef(
          message="multiple effect vars",
          span=unknown_span(),
        )
      }
  }
  EffectSet::{ consts, rest }
}

///|
fn effect_set_from_atoms(
  env : TypeEnv,
  effects : Array[@core.EffectAtom],
) -> EffectSet raise TypeError {
  effect_set_from_atoms_inner(env, effects, {})
}

///|
fn effect_set_from_atoms_inner(
  env : TypeEnv,
  effects : Array[@core.EffectAtom],
  visiting : Map[String, Bool],
) -> EffectSet raise TypeError {
  let mut out = effect_set_empty()
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(name) => {
        let consts : Map[String, Bool] = {}
        consts[name] = true
        out = effect_set_merge(out, EffectSet::{ consts, rest: None })
      }
      @core.EffectAtom::Var(name) => {
        let resolved = resolve_effect_var(env, name, visiting)
        out = effect_set_merge(out, resolved)
      }
    }
  }
  out
}

///|
fn resolve_effect_var(
  env : TypeEnv,
  name : String,
  visiting : Map[String, Bool],
) -> EffectSet raise TypeError {
  if visiting.contains(name) {
    EffectSet::{ consts: {}, rest: Some(name) }
  } else {
    match env.effect_subs.get(name) {
      Some(effects) => {
        let next : Map[String, Bool] = {}
        for key, val in visiting {
          next[key] = val
        }
        next[name] = true
        effect_set_from_atoms_inner(env, effects, next)
      }
      None => EffectSet::{ consts: {}, rest: Some(name) }
    }
  }
}

///|
fn effect_set_to_atoms(set : EffectSet) -> Array[@core.EffectAtom] {
  let out : Array[@core.EffectAtom] = []
  for name, _ in set.consts {
    out.push(@core.EffectAtom::Const(name))
  }
  match set.rest {
    Some(name) => out.push(@core.EffectAtom::Var(name))
    None => ()
  }
  out
}

///|
fn effect_consts_subset(
  small : Map[String, Bool],
  large : Map[String, Bool],
) -> Bool {
  for name, _ in small {
    if not(large.contains(name)) {
      return false
    }
  }
  true
}

///|
fn effect_consts_equal(
  left : Map[String, Bool],
  right : Map[String, Bool],
) -> Bool {
  effect_consts_subset(left, right) && effect_consts_subset(right, left)
}

///|
fn effect_consts_minus(
  left : Map[String, Bool],
  right : Map[String, Bool],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for name, _ in left {
    if not(right.contains(name)) {
      out[name] = true
    }
  }
  out
}

///|
fn effect_var_occurs(
  env : TypeEnv,
  name : String,
  set : EffectSet,
) -> Bool raise TypeError {
  match set.rest {
    Some(var_name) =>
      if var_name == name {
        true
      } else {
        match env.effect_subs.get(var_name) {
          Some(effects) =>
            effect_var_occurs(env, name, effect_set_from_atoms(env, effects))
          None => false
        }
      }
    None => false
  }
}

///|
fn bind_effect_var(
  env : TypeEnv,
  name : String,
  set : EffectSet,
) -> Bool raise TypeError {
  match set.rest {
    Some(var_name) =>
      if var_name == name {
        if set.consts.length() == 0 {
          true
        } else {
          let rest = fresh_effect_var(env)
          let updated = EffectSet::{ consts: set.consts, rest: Some(rest) }
          env.effect_subs[name] = effect_set_to_atoms(updated)
          true
        }
      } else if effect_var_occurs(env, name, set) {
        false
      } else {
        env.effect_subs[name] = effect_set_to_atoms(set)
        true
      }
    None =>
      if effect_var_occurs(env, name, set) {
        false
      } else {
        env.effect_subs[name] = effect_set_to_atoms(set)
        true
      }
  }
}

///|
fn add_const_to_effect_var(
  env : TypeEnv,
  name : String,
  effect : String,
) -> Unit raise TypeError {
  match env.effect_subs.get(name) {
    None => {
      let rest = fresh_effect_var(env)
      env.effect_subs[name] = [
        @core.EffectAtom::Const(effect),
        @core.EffectAtom::Var(rest),
      ]
    }
    Some(effects) => {
      let current = effect_set_from_atoms(env, effects)
      let consts : Map[String, Bool] = {}
      for key, val in current.consts {
        consts[key] = val
      }
      consts[effect] = true
      let updated = EffectSet::{ consts, rest: current.rest }
      env.effect_subs[name] = effect_set_to_atoms(updated)
    }
  }
}

///|
fn ensure_effects_allowed(
  env : TypeEnv,
  scope_set : EffectSet,
  required_set : EffectSet,
) -> String? raise TypeError {
  let resolved_scope = effect_set_from_atoms(
    env,
    effect_set_to_atoms(scope_set),
  )
  let resolved_req = effect_set_from_atoms(
    env,
    effect_set_to_atoms(required_set),
  )
  let scope_var = scope_set.rest
  for name, _ in resolved_req.consts {
    if resolved_scope.consts.contains(name) {
      ()
    } else {
      match scope_var {
        Some(var_name) => add_const_to_effect_var(env, var_name, name)
        None => return Some(name)
      }
    }
  }
  match resolved_req.rest {
    None => None
    Some(req_var) =>
      match scope_var {
        Some(scope_var_name) =>
          if req_var == scope_var_name {
            None
          } else {
            let ok = bind_effect_var(env, req_var, EffectSet::{
              consts: {},
              rest: Some(scope_var_name),
            })
            if ok {
              None
            } else {
              Some("effect")
            }
          }
        None => Some("effect")
      }
  }
}

///|
fn unify_effects(
  env : TypeEnv,
  left : Array[@core.EffectAtom],
  right : Array[@core.EffectAtom],
) -> Bool raise TypeError {
  let a = effect_set_from_atoms(env, left)
  let b = effect_set_from_atoms(env, right)
  unify_effect_sets(env, a, b)
}

///|
fn unify_effect_sets(
  env : TypeEnv,
  left : EffectSet,
  right : EffectSet,
) -> Bool raise TypeError {
  match (left.rest, right.rest) {
    (None, None) => effect_consts_equal(left.consts, right.consts)
    (Some(var_name), None) =>
      if effect_consts_subset(left.consts, right.consts) {
        let diff = effect_consts_minus(right.consts, left.consts)
        bind_effect_var(env, var_name, EffectSet::{ consts: diff, rest: None })
      } else {
        false
      }
    (None, Some(var_name)) =>
      if effect_consts_subset(right.consts, left.consts) {
        let diff = effect_consts_minus(left.consts, right.consts)
        bind_effect_var(env, var_name, EffectSet::{ consts: diff, rest: None })
      } else {
        false
      }
    (Some(var_left), Some(var_right)) =>
      if effect_consts_equal(left.consts, right.consts) {
        if var_left == var_right {
          true
        } else {
          bind_effect_var(env, var_left, EffectSet::{
            consts: {},
            rest: Some(var_right),
          })
        }
      } else if effect_consts_subset(left.consts, right.consts) {
        let diff = effect_consts_minus(right.consts, left.consts)
        bind_effect_var(env, var_left, EffectSet::{
          consts: diff,
          rest: Some(var_right),
        })
      } else if effect_consts_subset(right.consts, left.consts) {
        let diff = effect_consts_minus(left.consts, right.consts)
        bind_effect_var(env, var_right, EffectSet::{
          consts: diff,
          rest: Some(var_left),
        })
      } else {
        false
      }
  }
}

///|
pub fn TypeEnv::new() -> TypeEnv {
  {
    bindings: {},
    addr_types: {},
    enum_defs: {},
    struct_defs: {},
    type_aliases: {},
    ctor_index: {},
    traits: {},
    trait_impls: {},
    fn_versions: {},
    purities: {},
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    next_var: 0,
    next_effect_var: 0,
    loop_depth: 0,
    active_rec_fn: None,
    active_rec_fn_has_type_params: false,
    subs: {},
    effect_subs: {},
  }
}

///|
pub fn TypeEnv::get(self : TypeEnv, name : String) -> @core.Type? {
  match self.bindings.get(name) {
    Some(scheme) => Some(instantiate_scheme(self, scheme))
    None => None
  }
}

///|
pub fn TypeEnv::get_scheme(self : TypeEnv, name : String) -> TypeScheme? {
  self.bindings.get(name)
}

///|
pub fn TypeEnv::get_purity(self : TypeEnv, name : String) -> Bool? {
  self.purities.get(name)
}

///|
pub fn TypeEnv::get_addr_type(self : TypeEnv, addr : String) -> @core.Type? {
  self.addr_types.get(addr)
}

///|
pub fn TypeEnv::get_expr_type(self : TypeEnv, span : @core.Span) -> @core.Type? {
  self.expr_types.get(span_key(span))
}

///|
pub fn TypeEnv::clone(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.copy(),
    addr_types: self.addr_types.copy(),
    enum_defs: self.enum_defs.copy(),
    struct_defs: self.struct_defs.copy(),
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
    fn_versions: self.fn_versions.copy(),
    purities: self.purities.copy(),
    expr_types: self.expr_types,
    num_vars: self.num_vars.copy(),
    var_trait_bounds: self.var_trait_bounds.copy(),
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    loop_depth: self.loop_depth,
    active_rec_fn: self.active_rec_fn,
    active_rec_fn_has_type_params: self.active_rec_fn_has_type_params,
    subs: self.subs.copy(),
    effect_subs: self.effect_subs.copy(),
  }
}

///|
pub fn TypeEnv::fork_for_check(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.copy(),
    addr_types: self.addr_types.copy(),
    enum_defs: self.enum_defs.copy(),
    struct_defs: self.struct_defs.copy(),
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
    fn_versions: self.fn_versions.copy(),
    purities: self.purities.copy(),
    expr_types: self.expr_types,
    num_vars: self.num_vars.copy(),
    var_trait_bounds: self.var_trait_bounds.copy(),
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    loop_depth: self.loop_depth,
    active_rec_fn: self.active_rec_fn,
    active_rec_fn_has_type_params: self.active_rec_fn_has_type_params,
    subs: self.subs.copy(),
    effect_subs: self.effect_subs.copy(),
  }
}

///|
/// Clone as an independent module-check environment.
/// Unlike `clone`/`fork_for_check`, this does not share `expr_types`.
pub fn TypeEnv::clone_for_module(self : TypeEnv) -> TypeEnv {
  {
    bindings: self.bindings.copy(),
    addr_types: {},
    enum_defs: self.enum_defs.copy(),
    struct_defs: self.struct_defs.copy(),
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
    fn_versions: self.fn_versions.copy(),
    purities: self.purities.copy(),
    expr_types: {},
    num_vars: {},
    var_trait_bounds: {},
    next_var: 0,
    next_effect_var: 0,
    loop_depth: 0,
    active_rec_fn: None,
    active_rec_fn_has_type_params: false,
    subs: {},
    effect_subs: {},
  }
}

///|
pub fn TypeEnv::set(self : TypeEnv, name : String, ty : @core.Type) -> Unit {
  self.set_scheme(name, TypeScheme::{
    vars: [],
    num_vars: [],
    effect_vars: [],
    trait_bounds: {},
    ty,
  })
}

///|
pub fn TypeEnv::set_scheme(
  self : TypeEnv,
  name : String,
  scheme : TypeScheme,
) -> Unit {
  self.bindings[name] = scheme
}

///|
pub fn TypeEnv::set_exported_scheme(
  self : TypeEnv,
  name : String,
  scheme : TypeScheme,
) -> Unit {
  let next_ty = resolve_type(self, scheme.ty)
  match self.bindings.get(name) {
    Some(prev_scheme) => {
      let prev_ty = resolve_type(self, prev_scheme.ty)
      match (prev_ty, next_ty) {
        (@core.Type::Func(..), @core.Type::Func(..)) => {
          let current = match self.fn_versions.get(name) {
            Some(version) => version
            None => semver_init()
          }
          let bump = classify_function_api_change(self, prev_ty, next_ty)
          self.fn_versions[name] = semver_apply(current, bump)
        }
        (@core.Type::Func(..), _) => {
          let current = match self.fn_versions.get(name) {
            Some(version) => version
            None => semver_init()
          }
          self.fn_versions[name] = semver_apply(current, ApiVersionBump::Major)
        }
        (_, @core.Type::Func(..)) => self.fn_versions[name] = semver_init()
        _ => ()
      }
    }
    None =>
      match next_ty {
        @core.Type::Func(..) => self.fn_versions[name] = semver_init()
        _ => ()
      }
  }
  self.bindings[name] = scheme
}

///|
pub fn TypeEnv::set_purity(self : TypeEnv, name : String, pure : Bool) -> Unit {
  self.purities[name] = pure
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

///|
pub fn TypeEnv::has_trait(self : TypeEnv, name : String) -> Bool {
  self.traits.contains(name)
}

///|
pub fn TypeEnv::set_trait(self : TypeEnv, name : String) -> Unit {
  self.set_trait_info(name, TraitDefInfo::{
    supertraits: [],
    open_impl: false,
    is_local: true,
  })
}

///|
pub fn TypeEnv::set_trait_info(
  self : TypeEnv,
  name : String,
  info : TraitDefInfo,
) -> Unit {
  self.traits[name] = info
}

///|
pub fn TypeEnv::get_trait_info(self : TypeEnv, name : String) -> TraitDefInfo? {
  self.traits.get(name)
}

///|
pub fn TypeEnv::trait_is_open(self : TypeEnv, name : String) -> Bool {
  match self.traits.get(name) {
    Some(info) => info.open_impl
    None => false
  }
}

///|
pub fn TypeEnv::trait_is_local(self : TypeEnv, name : String) -> Bool {
  match self.traits.get(name) {
    Some(info) => info.is_local
    None => false
  }
}

///|
pub fn TypeEnv::import_trait(
  self : TypeEnv,
  name : String,
  open_impl : Bool,
  supertraits : Array[String],
) -> Unit {
  self.set_trait_info(name, TraitDefInfo::{
    supertraits,
    open_impl,
    is_local: false,
  })
}

///|
pub fn TypeEnv::trait_supertraits(
  self : TypeEnv,
  name : String,
) -> Array[String] {
  match self.traits.get(name) {
    Some(info) => info.supertraits.copy()
    None => []
  }
}

///|
pub fn TypeEnv::trait_names(self : TypeEnv) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.traits {
    names.push(name)
  }
  names
}

///|
pub fn TypeEnv::trait_impls_for(
  self : TypeEnv,
  name : String,
) -> Array[TraitImplDef] {
  match self.trait_impls.get(name) {
    Some(items) => items
    None => []
  }
}

///|
pub fn TypeEnv::add_trait_impl(
  self : TypeEnv,
  name : String,
  impl_def : TraitImplDef,
) -> Unit {
  let items = self.trait_impls_for(name)
  let next = items.copy()
  next.push(impl_def)
  self.trait_impls[name] = next
}

///|
pub fn TypeEnv::get_fn_version(self : TypeEnv, name : String) -> ApiSemver? {
  self.fn_versions.get(name)
}

///|
pub fn TypeEnv::set_addr_type(
  self : TypeEnv,
  addr : String,
  ty : @core.Type,
) -> Unit {
  self.addr_types[addr] = ty
}
