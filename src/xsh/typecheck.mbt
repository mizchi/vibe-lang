///|
/// Type checking for xsh
suberror TypeError {
  UnknownName(String)
  UnknownType(String)
  Mismatch(expected~ : Type, actual~ : Type)
  BadCall(String)
  BadRec(String)
  BadMatch(String)
  NonExhaustiveMatch
  BadTypeDef(String)
  EffectNotAllowed(String)
} derive(Show, Eq)

///|
pub struct CtorInfo {
  type_name : String
  params : Array[String]
  payload : Type
} derive(Show, Eq)

///|
priv struct CtorInstance {
  payload : Type
  ret : Type
}

///|
pub struct EnumDef {
  name : String
  params : Array[String]
  ctors : Array[TypeCtor]
} derive(Show, Eq)

///|
pub struct TypeScheme {
  vars : Array[Int]
  effect_vars : Array[String]
  ty : Type
} derive(Show, Eq)

///|
pub struct TypeAlias {
  name : String
  params : Array[String]
  target : Type
} derive(Show, Eq)

///|
pub struct TypeEnv {
  bindings : Map[String, TypeScheme]
  addr_types : Map[String, Type]
  enum_defs : Map[String, EnumDef]
  type_aliases : Map[String, TypeAlias]
  ctor_index : Map[String, CtorInfo]
  purities : Map[String, Bool]
  mut next_var : Int
  mut next_effect_var : Int
  subs : Map[Int, Type]
  effect_subs : Map[String, Array[EffectAtom]]
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
fn effect_scope_from_list(effects : Array[EffectAtom]) -> EffectScope {
  let allowed : Map[String, Bool] = {}
  let mut rest : String? = None
  for effect in effects {
    match effect {
      EffectAtom::Const(name) => allowed[name] = true
      EffectAtom::Var(name) =>
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
  effects : Array[EffectAtom],
) -> Array[EffectAtom] raise TypeError {
  let out : Array[EffectAtom] = []
  let seen : Map[String, Bool] = {}
  let mut seen_var : String? = None
  for effect in effects {
    match effect {
      EffectAtom::Const(name) =>
        if not(seen.contains(name)) {
          seen[name] = true
          out.push(effect)
        }
      EffectAtom::Var(name) =>
        match seen_var {
          Some(existing) =>
            if existing != name {
              raise TypeError::BadTypeDef("multiple effect vars")
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
  effects : Array[EffectAtom],
) -> Unit raise TypeError {
  if scope.allow_all {
    return ()
  }
  let scope_set = effect_set_from_scope(scope)
  let required_set = effect_set_from_atoms(env, effects)
  match ensure_effects_allowed(env, scope_set, required_set) {
    Some(name) => raise TypeError::EffectNotAllowed(name)
    None => ()
  }
}

///|
fn builtin_effects(name : String) -> Array[EffectAtom] {
  match name {
    "sh" => [EffectAtom::Const("Stdout")]
    _ => []
  }
}

///|
fn effect_scope_extend(
  scope : EffectScope,
  extra : Array[EffectAtom],
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
        EffectAtom::Const(name) => allowed[name] = true
        EffectAtom::Var(name) =>
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
        raise TypeError::BadTypeDef("multiple effect vars")
      }
  }
  EffectSet::{ consts, rest }
}

///|
fn effect_set_from_atoms(
  env : TypeEnv,
  effects : Array[EffectAtom],
) -> EffectSet raise TypeError {
  effect_set_from_atoms_inner(env, effects, {})
}

///|
fn effect_set_from_atoms_inner(
  env : TypeEnv,
  effects : Array[EffectAtom],
  visiting : Map[String, Bool],
) -> EffectSet raise TypeError {
  let mut out = effect_set_empty()
  for effect in effects {
    match effect {
      EffectAtom::Const(name) => {
        let consts : Map[String, Bool] = {}
        consts[name] = true
        out = effect_set_merge(out, EffectSet::{ consts, rest: None })
      }
      EffectAtom::Var(name) => {
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
fn effect_set_to_atoms(set : EffectSet) -> Array[EffectAtom] {
  let out : Array[EffectAtom] = []
  for name, _ in set.consts {
    out.push(EffectAtom::Const(name))
  }
  match set.rest {
    Some(name) => out.push(EffectAtom::Var(name))
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
      env.effect_subs[name] = [EffectAtom::Const(effect), EffectAtom::Var(rest)]
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
  left : Array[EffectAtom],
  right : Array[EffectAtom],
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
    type_aliases: {},
    ctor_index: {},
    purities: {},
    next_var: 0,
    next_effect_var: 0,
    subs: {},
    effect_subs: {},
  }
}

///|
pub fn TypeEnv::get(self : TypeEnv, name : String) -> Type? {
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
pub fn TypeEnv::get_addr_type(self : TypeEnv, addr : String) -> Type? {
  self.addr_types.get(addr)
}

///|
pub fn TypeEnv::clone(self : TypeEnv) -> TypeEnv {
  let bindings : Map[String, TypeScheme] = {}
  for name, scheme in self.bindings {
    bindings[name] = scheme
  }
  let addr_types : Map[String, Type] = {}
  for addr, ty in self.addr_types {
    addr_types[addr] = ty
  }
  let enum_defs : Map[String, EnumDef] = {}
  for name, def in self.enum_defs {
    enum_defs[name] = def
  }
  let type_aliases : Map[String, TypeAlias] = {}
  for name, type_alias in self.type_aliases {
    type_aliases[name] = type_alias
  }
  let ctor_index : Map[String, CtorInfo] = {}
  for name, info in self.ctor_index {
    ctor_index[name] = info
  }
  let purities : Map[String, Bool] = {}
  for name, pure in self.purities {
    purities[name] = pure
  }
  let subs : Map[Int, Type] = {}
  for id, ty in self.subs {
    subs[id] = ty
  }
  let effect_subs : Map[String, Array[EffectAtom]] = {}
  for name, effects in self.effect_subs {
    effect_subs[name] = effects
  }
  {
    bindings,
    addr_types,
    enum_defs,
    type_aliases,
    ctor_index,
    purities,
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    subs,
    effect_subs,
  }
}

///|
pub fn TypeEnv::set(self : TypeEnv, name : String, ty : Type) -> Unit {
  self.bindings[name] = TypeScheme::{ vars: [], effect_vars: [], ty }
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
pub fn TypeEnv::set_purity(self : TypeEnv, name : String, pure : Bool) -> Unit {
  self.purities[name] = pure
}

///|
pub fn TypeEnv::get_enum_def(self : TypeEnv, name : String) -> EnumDef? {
  self.enum_defs.get(name)
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
pub fn TypeEnv::set_addr_type(self : TypeEnv, addr : String, ty : Type) -> Unit {
  self.addr_types[addr] = ty
}

///|
pub fn type_check(ast : Module) -> TypeEnv raise TypeError {
  type_check_with_aliases(ast, {})
}

///|
/// Type check with import aliases (qualified names treated as external).
pub fn type_check_with_aliases(
  ast : Module,
  aliases : Map[String, Ref],
) -> TypeEnv raise TypeError {
  let env = TypeEnv::new()
  ensure_prelude_option(env)
  ensure_prelude_functions(env, aliases)
  type_check_stmts(env, ast.stmts, aliases, effect_scope_all(), false)
}

///|
pub fn type_check_with_env(
  env : TypeEnv,
  ast : Module,
  aliases : Map[String, Ref],
) -> TypeEnv raise TypeError {
  ensure_prelude_option(env)
  ensure_prelude_functions(env, aliases)
  type_check_stmts(env, ast.stmts, aliases, effect_scope_all(), false)
}

///|
fn type_check_stmts(
  env : TypeEnv,
  stmts : Array[Stmt],
  aliases : Map[String, Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> TypeEnv raise TypeError {
  for stmt in stmts {
    match stmt {
      Stmt::Let(rec~, name~, expr~) => {
        let scheme = type_let_expr(
          env, rec, name, expr, aliases, effects, allow_effect,
        )
        env.set_scheme(name, scheme)
        let info = purity_for_let(env, rec, name, expr)
        env.set_purity(name, info.value)
      }
      Stmt::EnumDef(name~, params~, ctors~) =>
        register_enum_def(env, name, params, ctors)
      Stmt::TypeAlias(name~, params~, target~) =>
        register_type_alias(env, name, params, target)
      Stmt::Expr(expr~) => {
        let _ = type_expr_eff(env, expr, aliases, effects, allow_effect)

      }
      Stmt::Flake(_) => ()
      Stmt::Alias(name~, target~) =>
        match target {
          AliasTarget::Module(_) => ()
          AliasTarget::Name(target_name) =>
            match env.get_scheme(target_name) {
              Some(scheme) => env.set_scheme(name, scheme)
              None => raise TypeError::UnknownName(target_name)
            }
        }
      Stmt::Import(..) => ()
      Stmt::Test(name~, body~) => {
        let _ = name
        let _ = type_check_stmts(
          clone_env(env),
          body.stmts,
          aliases,
          effects,
          allow_effect,
        )

      }
    }
  }
  env
}

///|
fn clone_env(env : TypeEnv) -> TypeEnv {
  env.clone()
}

///|
fn ensure_unique_params(params : Array[String]) -> Unit raise TypeError {
  let seen : Map[String, Bool] = {}
  for param in params {
    if seen.contains(param) {
      raise TypeError::BadTypeDef("duplicate type param: " + param)
    }
    seen[param] = true
  }
}

///|
fn ensure_prelude_option(env : TypeEnv) -> Unit raise TypeError {
  if env.get_enum_def("Option") is Some(_) {
    return
  }
  let ctors : Array[TypeCtor] = [
    TypeCtor::{ name: "Some", args: [Type::Param("T")] },
    TypeCtor::{ name: "None", args: [] },
  ]
  register_enum_def(env, "Option", ["T"], ctors)
}

///|
fn ensure_prelude_functions(
  env : TypeEnv,
  aliases : Map[String, Ref],
) -> Unit raise TypeError {
  match env.get_purity("__prelude_loaded") {
    Some(_) => ()
    None => {
      let prelude = prelude_ast()
      let _ = type_check_stmts(
        env,
        prelude.stmts,
        aliases,
        effect_scope_all(),
        false,
      )
      env.set_purity("__prelude_loaded", true)
    }
  }
}

///|
fn fresh_type_var(env : TypeEnv) -> Type {
  let id = env.next_var
  env.next_var += 1
  Type::Var(id)
}

///|
fn fresh_effect_var(env : TypeEnv) -> String {
  let id = env.next_effect_var
  env.next_effect_var += 1
  "$e" + id.to_string()
}

///|
fn instantiate_scheme(env : TypeEnv, scheme : TypeScheme) -> Type {
  let mapping : Map[Int, Type] = {}
  for id in scheme.vars {
    mapping[id] = fresh_type_var(env)
  }
  let effect_mapping : Map[String, String] = {}
  for name in scheme.effect_vars {
    effect_mapping[name] = fresh_effect_var(env)
  }
  let substituted = substitute_type_vars(scheme.ty, mapping)
  let replaced = substitute_effect_vars(substituted, effect_mapping)
  resolve_type(env, replaced)
}

///|
fn resolve_type(env : TypeEnv, ty : Type) -> Type {
  match ty {
    Type::Var(id) =>
      match env.subs.get(id) {
        Some(t) => {
          let resolved = resolve_type(env, t)
          env.subs[id] = resolved
          resolved
        }
        None => ty
      }
    Type::Tuple(items) => {
      let out : Array[Type] = []
      for item in items {
        out.push(resolve_type(env, item))
      }
      Type::Tuple(out)
    }
    Type::Record(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = resolve_type(env, item)
      }
      Type::Record(out)
    }
    Type::Array(inner) => Type::Array(resolve_type(env, inner))
    Type::Map(inner) => Type::Map(resolve_type(env, inner))
    Type::ArrayBuilder(inner) => Type::ArrayBuilder(resolve_type(env, inner))
    Type::MapBuilder(inner) => Type::MapBuilder(resolve_type(env, inner))
    Type::Variant(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = resolve_type(env, item)
      }
      Type::Variant(out)
    }
    Type::Named(name~, args~) => {
      let out : Array[Type] = []
      for arg in args {
        out.push(resolve_type(env, arg))
      }
      Type::Named(name~, args=out)
    }
    Type::Func(params~, ret~, effects~) => {
      let out : Array[FuncParam] = []
      for param in params {
        out.push(FuncParam::{
          name: param.name,
          label: param.label,
          ty: resolve_type(env, param.ty),
        })
      }
      Type::Func(params=out, ret=resolve_type(env, ret), effects~)
    }
    _ => ty
  }
}

///|
fn substitute_type_vars(ty : Type, subs : Map[Int, Type]) -> Type {
  match ty {
    Type::Var(id) =>
      match subs.get(id) {
        Some(t) => t
        None => ty
      }
    Type::Tuple(items) => {
      let out : Array[Type] = []
      for item in items {
        out.push(substitute_type_vars(item, subs))
      }
      Type::Tuple(out)
    }
    Type::Record(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = substitute_type_vars(item, subs)
      }
      Type::Record(out)
    }
    Type::Array(inner) => Type::Array(substitute_type_vars(inner, subs))
    Type::Map(inner) => Type::Map(substitute_type_vars(inner, subs))
    Type::ArrayBuilder(inner) =>
      Type::ArrayBuilder(substitute_type_vars(inner, subs))
    Type::MapBuilder(inner) =>
      Type::MapBuilder(substitute_type_vars(inner, subs))
    Type::Variant(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = substitute_type_vars(item, subs)
      }
      Type::Variant(out)
    }
    Type::Named(name~, args~) => {
      let out : Array[Type] = []
      for arg in args {
        out.push(substitute_type_vars(arg, subs))
      }
      Type::Named(name~, args=out)
    }
    Type::Func(params~, ret~, effects~) => {
      let out : Array[FuncParam] = []
      for param in params {
        out.push(FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_vars(param.ty, subs),
        })
      }
      Type::Func(params=out, ret=substitute_type_vars(ret, subs), effects~)
    }
    _ => ty
  }
}

///|
fn substitute_effect_vars(ty : Type, subs : Map[String, String]) -> Type {
  match ty {
    Type::Tuple(items) => {
      let out : Array[Type] = []
      for item in items {
        out.push(substitute_effect_vars(item, subs))
      }
      Type::Tuple(out)
    }
    Type::Record(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = substitute_effect_vars(item, subs)
      }
      Type::Record(out)
    }
    Type::Array(inner) => Type::Array(substitute_effect_vars(inner, subs))
    Type::Map(inner) => Type::Map(substitute_effect_vars(inner, subs))
    Type::ArrayBuilder(inner) =>
      Type::ArrayBuilder(substitute_effect_vars(inner, subs))
    Type::MapBuilder(inner) =>
      Type::MapBuilder(substitute_effect_vars(inner, subs))
    Type::Variant(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = substitute_effect_vars(item, subs)
      }
      Type::Variant(out)
    }
    Type::Named(name~, args~) => {
      let out : Array[Type] = []
      for arg in args {
        out.push(substitute_effect_vars(arg, subs))
      }
      Type::Named(name~, args=out)
    }
    Type::Func(params~, ret~, effects~) => {
      let out : Array[FuncParam] = []
      for param in params {
        out.push(FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_effect_vars(param.ty, subs),
        })
      }
      let eff_out : Array[EffectAtom] = []
      for effect in effects {
        match effect {
          EffectAtom::Const(_) => eff_out.push(effect)
          EffectAtom::Var(name) =>
            match subs.get(name) {
              Some(mapped) => eff_out.push(EffectAtom::Var(mapped))
              None => eff_out.push(effect)
            }
        }
      }
      Type::Func(
        params=out,
        ret=substitute_effect_vars(ret, subs),
        effects=eff_out,
      )
    }
    _ => ty
  }
}

///|
fn substitute_type(ty : Type, subs : Map[String, Type]) -> Type {
  match ty {
    Type::Param(name) =>
      match subs.get(name) {
        Some(t) => t
        None => ty
      }
    Type::Tuple(items) => {
      let out : Array[Type] = []
      for item in items {
        out.push(substitute_type(item, subs))
      }
      Type::Tuple(out)
    }
    Type::Record(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = substitute_type(item, subs)
      }
      Type::Record(out)
    }
    Type::Array(inner) => Type::Array(substitute_type(inner, subs))
    Type::Map(inner) => Type::Map(substitute_type(inner, subs))
    Type::ArrayBuilder(inner) =>
      Type::ArrayBuilder(substitute_type(inner, subs))
    Type::MapBuilder(inner) => Type::MapBuilder(substitute_type(inner, subs))
    Type::Variant(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = substitute_type(item, subs)
      }
      Type::Variant(out)
    }
    Type::Named(name~, args~) => {
      let out : Array[Type] = []
      for arg in args {
        out.push(substitute_type(arg, subs))
      }
      Type::Named(name~, args=out)
    }
    Type::Func(params~, ret~, effects~) => {
      let out : Array[FuncParam] = []
      for param in params {
        out.push(FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type(param.ty, subs),
        })
      }
      Type::Func(params=out, ret=substitute_type(ret, subs), effects~)
    }
    _ => ty
  }
}

///|
fn instantiate_ctor(env : TypeEnv, info : CtorInfo) -> CtorInstance {
  let mapping : Map[String, Type] = {}
  let args : Array[Type] = []
  for param in info.params {
    let ty_var = fresh_type_var(env)
    mapping[param] = ty_var
    args.push(ty_var)
  }
  let payload = substitute_type(info.payload, mapping)
  let ret = Type::Named(name=info.type_name, args~)
  { payload, ret }
}

///|
fn register_enum_def(
  env : TypeEnv,
  name : String,
  params : Array[String],
  ctors : Array[TypeCtor],
) -> Unit raise TypeError {
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef("duplicate type: " + name)
  }
  if ctors.is_empty() {
    raise TypeError::BadTypeDef("empty type: " + name)
  }
  ensure_unique_params(params)
  env.set_enum_def(name, EnumDef::{ name, params, ctors })
  let ctor_map : Map[String, Type] = {}
  for ctor in ctors {
    if ctor_map.contains(ctor.name) {
      raise TypeError::BadTypeDef("duplicate ctor: " + ctor.name)
    }
    let payload = ctor_payload_type(env, ctor)
    ctor_map[ctor.name] = payload
  }
  for ctor_name, payload in ctor_map {
    if env.get_ctor(ctor_name) is Some(_) {
      raise TypeError::BadTypeDef("ctor already defined: " + ctor_name)
    }
    env.set_ctor(ctor_name, CtorInfo::{ type_name: name, params, payload })
  }
}

///|
fn register_type_alias(
  env : TypeEnv,
  name : String,
  params : Array[String],
  target : Type,
) -> Unit raise TypeError {
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef("duplicate type: " + name)
  }
  ensure_unique_params(params)
  let normalized = normalize_type(env, target)
  env.set_type_alias(name, TypeAlias::{ name, params, target: normalized })
}

///|
fn ctor_payload_type(env : TypeEnv, ctor : TypeCtor) -> Type raise TypeError {
  if ctor.args.length() == 0 {
    Type::Unit
  } else if ctor.args.length() == 1 {
    normalize_type(env, ctor.args[0])
  } else {
    let items : Array[Type] = []
    for arg in ctor.args {
      items.push(normalize_type(env, arg))
    }
    Type::Tuple(items)
  }
}

///|
fn type_expr_eff(
  env : TypeEnv,
  expr : Expr,
  aliases : Map[String, Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> Type raise TypeError {
  match expr {
    Expr::Int(_) => Type::Int
    Expr::Bool(_) => Type::Bool
    Expr::String(_) => Type::String
    Expr::Ident(name) =>
      match env.get(name) {
        Some(ty) => ty
        None =>
          if has_alias_prefix(name, aliases) {
            Type::Unit
          } else {
            match env.get_ctor(name) {
              Some(info) => {
                let inst = instantiate_ctor(env, info)
                inst.ret
              }
              None =>
                if is_ctor_name(name) {
                  let map : Map[String, Type] = {}
                  map[name] = Type::Unit
                  Type::Variant(map)
                } else {
                  raise TypeError::UnknownName(name)
                }
            }
          }
      }
    Expr::Call(name~, args~) =>
      if has_alias_prefix(name, aliases) {
        Type::Unit
      } else {
        type_call(env, name, args, aliases, effects, allow_effect)
      }
    Expr::Tuple(items) => {
      let tys : Array[Type] = []
      for item in items {
        tys.push(type_expr_eff(env, item, aliases, effects, allow_effect))
      }
      Type::Tuple(tys)
    }
    Expr::Record(fields) => {
      let map : Map[String, Type] = {}
      for field in fields {
        let ty = type_expr_eff(env, field.expr, aliases, effects, allow_effect)
        map[field.name] = ty
      }
      Type::Record(map)
    }
    Expr::Array(items) =>
      if items.is_empty() {
        Type::Array(Type::Unit)
      } else {
        let first = type_expr_eff(env, items[0], aliases, effects, allow_effect)
        let elem_ty = normalize_type(env, first)
        for i in 1..<items.length() {
          let item_ty = type_expr_eff(
            env,
            items[i],
            aliases,
            effects,
            allow_effect,
          )
          if not(type_equal(env, elem_ty, item_ty)) {
            raise TypeError::Mismatch(expected=elem_ty, actual=item_ty)
          }
        }
        Type::Array(elem_ty)
      }
    Expr::Map(fields) =>
      if fields.is_empty() {
        Type::Map(Type::Unit)
      } else {
        let first = type_expr_eff(
          env,
          fields[0].expr,
          aliases,
          effects,
          allow_effect,
        )
        let val_ty = normalize_type(env, first)
        for i in 1..<fields.length() {
          let item_ty = type_expr_eff(
            env,
            fields[i].expr,
            aliases,
            effects,
            allow_effect,
          )
          if not(type_equal(env, val_ty, item_ty)) {
            raise TypeError::Mismatch(expected=val_ty, actual=item_ty)
          }
        }
        Type::Map(val_ty)
      }
    Expr::If(cond~, then_body~, else_body~) => {
      let cond_ty = type_expr_eff(env, cond, aliases, effects, allow_effect)
      if not(type_equal(env, cond_ty, Type::Bool)) {
        raise TypeError::Mismatch(expected=Type::Bool, actual=cond_ty)
      }
      let then_ty = type_block(env, then_body, aliases, effects, allow_effect)
      let else_ty = type_block(env, else_body, aliases, effects, allow_effect)
      if not(type_equal(env, then_ty, else_ty)) {
        raise TypeError::Mismatch(expected=then_ty, actual=else_ty)
      }
      then_ty
    }
    Expr::Block(body~) => type_block(env, body, aliases, effects, allow_effect)
    Expr::Try(try_body~, catch_body~) => {
      let try_scope = effect_scope_extend(effects, [EffectAtom::Const("Error")])
      let try_ty = type_block(env, try_body, aliases, try_scope, allow_effect)
      let catch_ty = type_block(env, catch_body, aliases, effects, allow_effect)
      if not(type_equal(env, try_ty, catch_ty)) {
        raise TypeError::Mismatch(expected=try_ty, actual=catch_ty)
      }
      try_ty
    }
    Expr::Match(scrutinee~, arms~) => {
      if arms.is_empty() {
        raise TypeError::BadMatch("empty match")
      }
      let scrutinee_ty = normalize_type(
        env,
        type_expr_eff(env, scrutinee, aliases, effects, allow_effect),
      )
      let mut result : Type? = None
      let mut has_wildcard = false
      let mut has_ctor = false
      let covered : Map[String, Bool] = {}
      for arm in arms {
        if is_top_wildcard(arm.pat) {
          has_wildcard = true
        }
        match arm.pat {
          Pat::Ctor(name~, ..) => {
            has_ctor = true
            covered[name] = true
          }
          _ => ()
        }
        let arm_env = clone_env(env)
        let bindings = collect_pattern_bindings(env, arm.pat, scrutinee_ty)
        for name, ty in bindings {
          arm_env.set(name, ty)
        }
        match arm.cond {
          Some(c) => {
            let g_ty = type_expr_eff(arm_env, c, aliases, effects, allow_effect)
            if not(type_equal(env, g_ty, Type::Bool)) {
              raise TypeError::Mismatch(expected=Type::Bool, actual=g_ty)
            }
          }
          None => ()
        }
        let arm_ty = type_expr_eff(
          arm_env,
          arm.expr,
          aliases,
          effects,
          allow_effect,
        )
        match result {
          Some(t) =>
            if not(type_equal(env, t, arm_ty)) {
              raise TypeError::Mismatch(expected=t, actual=arm_ty)
            }
          None => result = Some(arm_ty)
        }
      }
      if not(has_wildcard) {
        match scrutinee_ty {
          Type::Variant(types) => {
            let mut missing = false
            for name, _ in types {
              if not(covered.contains(name)) {
                missing = true
                break
              }
            }
            if missing {
              raise TypeError::NonExhaustiveMatch
            }
          }
          _ => if not(has_ctor) { raise TypeError::NonExhaustiveMatch }
        }
      }
      match result {
        Some(t) => t
        None => Type::Unit
      }
    }
    Expr::Do(body~) => type_block(env, body, aliases, effects, true)
    Expr::Fn(params~, ret~, effects=fn_effects, body~) => {
      let scope_env = clone_env(env)
      let resolved_params : Array[FuncParam] = []
      for param in params {
        let resolved = normalize_type(env, param.ty)
        let binding_ty = if param.label == ParamLabel::Optional {
          Type::Named(name="Option", args=[resolved])
        } else {
          resolved
        }
        scope_env.set(param.name, binding_ty)
        resolved_params.push(FuncParam::{
          name: param.name,
          label: param.label,
          ty: resolved,
        })
      }
      let normalized_effects = normalize_effects(fn_effects)
      let fn_scope = effect_scope_from_list(normalized_effects)
      let body_ty = type_block(scope_env, body, aliases, fn_scope, allow_effect)
      let resolved_effects = effect_set_to_atoms(
        effect_set_from_atoms(scope_env, normalized_effects),
      )
      let final_ret = match ret {
        Some(r) => {
          let resolved = normalize_type(env, r)
          if not(type_equal(env, resolved, body_ty)) {
            raise TypeError::Mismatch(expected=resolved, actual=body_ty)
          }
          resolved
        }
        None => body_ty
      }
      Type::Func(
        params=resolved_params,
        ret=final_ret,
        effects=resolved_effects,
      )
    }
  }
}

///|
fn is_top_wildcard(pat : Pat) -> Bool {
  match pat {
    Pat::Wildcard => true
    Pat::Bind(_) => true
    _ => false
  }
}

///|
fn collect_pattern_bindings(
  env : TypeEnv,
  pat : Pat,
  scrutinee_ty : Type,
) -> Map[String, Type] raise TypeError {
  let out : Map[String, Type] = {}
  let normalized = normalize_type(env, scrutinee_ty)
  collect_pattern_bindings_inner(env, out, pat, normalized)
  out
}

///|
fn generalize(env : TypeEnv, ty : Type) -> TypeScheme raise TypeError {
  let resolved = resolve_type(env, ty)
  let normalized = normalize_type(env, resolved)
  let free_ty = free_vars_in_type(env, normalized)
  let free_env = free_vars_in_env(env)
  let vars : Array[Int] = []
  for id, _ in free_ty {
    if not(free_env.contains(id)) {
      vars.push(id)
    }
  }
  let free_effects = free_effect_vars_in_type(env, normalized)
  let free_effect_env = free_effect_vars_in_env(env)
  let effect_vars : Array[String] = []
  for name, _ in free_effects {
    if not(free_effect_env.contains(name)) {
      effect_vars.push(name)
    }
  }
  TypeScheme::{ vars, effect_vars, ty: normalized }
}

///|
fn free_vars_in_env(env : TypeEnv) -> Map[Int, Bool] {
  let out : Map[Int, Bool] = {}
  for _, scheme in env.bindings {
    let vars = free_vars_in_scheme(env, scheme)
    for id, _ in vars {
      out[id] = true
    }
  }
  out
}

///|
fn free_vars_in_scheme(env : TypeEnv, scheme : TypeScheme) -> Map[Int, Bool] {
  let out = free_vars_in_type(env, scheme.ty)
  for id in scheme.vars {
    out.remove(id)
  }
  out
}

///|
fn free_vars_in_type(env : TypeEnv, ty : Type) -> Map[Int, Bool] {
  let out : Map[Int, Bool] = {}
  collect_free_vars(env, ty, out)
  out
}

///|
fn collect_free_vars(env : TypeEnv, ty : Type, out : Map[Int, Bool]) -> Unit {
  match resolve_type(env, ty) {
    Type::Var(id) => out[id] = true
    Type::Tuple(items) =>
      for item in items {
        collect_free_vars(env, item, out)
      }
    Type::Record(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    Type::Array(inner) => collect_free_vars(env, inner, out)
    Type::Map(inner) => collect_free_vars(env, inner, out)
    Type::ArrayBuilder(inner) => collect_free_vars(env, inner, out)
    Type::MapBuilder(inner) => collect_free_vars(env, inner, out)
    Type::Variant(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    Type::Named(name=_, args~) =>
      for arg in args {
        collect_free_vars(env, arg, out)
      }
    Type::Func(params~, ret~, effects=_) => {
      collect_free_vars(env, ret, out)
      for param in params {
        collect_free_vars(env, param.ty, out)
      }
    }
    _ => ()
  }
}

///|
fn free_effect_vars_in_env(env : TypeEnv) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for _, scheme in env.bindings {
    let vars = free_effect_vars_in_scheme(env, scheme)
    for name, _ in vars {
      out[name] = true
    }
  }
  out
}

///|
fn free_effect_vars_in_scheme(
  env : TypeEnv,
  scheme : TypeScheme,
) -> Map[String, Bool] {
  let out = free_effect_vars_in_type(env, scheme.ty)
  for name in scheme.effect_vars {
    out.remove(name)
  }
  out
}

///|
fn free_effect_vars_in_type(env : TypeEnv, ty : Type) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  collect_free_effect_vars(env, ty, out)
  out
}

///|
fn collect_free_effect_vars(
  env : TypeEnv,
  ty : Type,
  out : Map[String, Bool],
) -> Unit {
  match resolve_type(env, ty) {
    Type::Tuple(items) =>
      for item in items {
        collect_free_effect_vars(env, item, out)
      }
    Type::Record(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    Type::Array(inner) => collect_free_effect_vars(env, inner, out)
    Type::Map(inner) => collect_free_effect_vars(env, inner, out)
    Type::ArrayBuilder(inner) => collect_free_effect_vars(env, inner, out)
    Type::MapBuilder(inner) => collect_free_effect_vars(env, inner, out)
    Type::Variant(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    Type::Named(name=_, args~) =>
      for arg in args {
        collect_free_effect_vars(env, arg, out)
      }
    Type::Func(params~, ret~, effects~) => {
      collect_free_effect_vars(env, ret, out)
      for param in params {
        collect_free_effect_vars(env, param.ty, out)
      }
      collect_free_effect_vars_in_effects(env, effects, out, {})
    }
    _ => ()
  }
}

///|
fn collect_free_effect_vars_in_effects(
  env : TypeEnv,
  effects : Array[EffectAtom],
  out : Map[String, Bool],
  visiting : Map[String, Bool],
) -> Unit {
  for effect in effects {
    match effect {
      EffectAtom::Const(_) => ()
      EffectAtom::Var(name) => collect_free_effect_var(env, name, out, visiting)
    }
  }
}

///|
fn collect_free_effect_var(
  env : TypeEnv,
  name : String,
  out : Map[String, Bool],
  visiting : Map[String, Bool],
) -> Unit {
  if visiting.contains(name) {
    out[name] = true
  } else {
    match env.effect_subs.get(name) {
      Some(effects) => {
        let next : Map[String, Bool] = {}
        for key, val in visiting {
          next[key] = val
        }
        next[name] = true
        collect_free_effect_vars_in_effects(env, effects, out, next)
      }
      None => out[name] = true
    }
  }
}

///|
fn collect_pattern_bindings_inner(
  env : TypeEnv,
  out : Map[String, Type],
  pat : Pat,
  scrutinee_ty : Type,
) -> Unit raise TypeError {
  match pat {
    Pat::Wildcard => ()
    Pat::Bind(name) => {
      if out.contains(name) {
        raise TypeError::BadMatch("duplicate bind: " + name)
      }
      out[name] = scrutinee_ty
    }
    Pat::Ctor(name~, args~) =>
      match scrutinee_ty {
        Type::Variant(types) =>
          match types.get(name) {
            Some(field_ty) =>
              if args.length() == 0 {
                ()
              } else if args.length() == 1 {
                collect_pattern_bindings_inner(env, out, args[0], field_ty)
              } else {
                match field_ty {
                  Type::Tuple(items) =>
                    if items.length() != args.length() {
                      raise TypeError::BadMatch("ctor arity")
                    } else {
                      for i in 0..<args.length() {
                        collect_pattern_bindings_inner(
                          env,
                          out,
                          args[i],
                          items[i],
                        )
                      }
                    }
                  _ => raise TypeError::BadMatch("ctor expects tuple")
                }
              }
            None => {
              let mut closed = true
              for ctor_name, _ in types {
                if env.get_ctor(ctor_name) is None {
                  closed = false
                  break
                }
              }
              if closed {
                raise TypeError::BadMatch("unknown ctor: " + name)
              } else {
                for arg in args {
                  collect_pattern_bindings_loose(out, arg)
                }
              }
            }
          }
        Type::Record(types) =>
          match types.get(name) {
            Some(field_ty) =>
              if args.length() == 0 {
                ()
              } else if args.length() == 1 {
                collect_pattern_bindings_inner(env, out, args[0], field_ty)
              } else {
                match field_ty {
                  Type::Tuple(items) =>
                    if items.length() != args.length() {
                      raise TypeError::BadMatch("ctor arity")
                    } else {
                      for i in 0..<args.length() {
                        collect_pattern_bindings_inner(
                          env,
                          out,
                          args[i],
                          items[i],
                        )
                      }
                    }
                  _ => raise TypeError::BadMatch("ctor expects tuple")
                }
              }
            None =>
              for arg in args {
                collect_pattern_bindings_loose(out, arg)
              }
          }
        _ => raise TypeError::BadMatch("expected ctor variant")
      }
    Pat::Int(_) =>
      if not(type_equal(env, scrutinee_ty, Type::Int)) {
        raise TypeError::Mismatch(expected=Type::Int, actual=scrutinee_ty)
      }
    Pat::Bool(_) =>
      if not(type_equal(env, scrutinee_ty, Type::Bool)) {
        raise TypeError::Mismatch(expected=Type::Bool, actual=scrutinee_ty)
      }
    Pat::String(_) =>
      if not(type_equal(env, scrutinee_ty, Type::String)) {
        raise TypeError::Mismatch(expected=Type::String, actual=scrutinee_ty)
      }
    Pat::Tuple(items) =>
      match scrutinee_ty {
        Type::Tuple(types) => {
          if items.length() != types.length() {
            raise TypeError::BadMatch("tuple arity")
          }
          for i in 0..<items.length() {
            collect_pattern_bindings_inner(env, out, items[i], types[i])
          }
        }
        _ => raise TypeError::BadMatch("expected tuple")
      }
    Pat::Record(fields) =>
      match scrutinee_ty {
        Type::Record(types) =>
          for field in fields {
            match types.get(field.name) {
              Some(field_ty) =>
                collect_pattern_bindings_inner(env, out, field.pat, field_ty)
              None => raise TypeError::BadMatch("missing field: " + field.name)
            }
          }
        _ => raise TypeError::BadMatch("expected record")
      }
  }
}

///|
fn collect_pattern_bindings_loose(
  out : Map[String, Type],
  pat : Pat,
) -> Unit raise TypeError {
  match pat {
    Pat::Wildcard => ()
    Pat::Bind(name) => {
      if out.contains(name) {
        raise TypeError::BadMatch("duplicate bind: " + name)
      }
      out[name] = Type::Unit
    }
    Pat::Ctor(name~, args~) => {
      let _ = name
      for arg in args {
        collect_pattern_bindings_loose(out, arg)
      }
    }
    Pat::Tuple(items) =>
      for item in items {
        collect_pattern_bindings_loose(out, item)
      }
    Pat::Record(fields) =>
      for field in fields {
        collect_pattern_bindings_loose(out, field.pat)
      }
    Pat::Int(_) | Pat::Bool(_) | Pat::String(_) => ()
  }
}

///|
fn type_block(
  env : TypeEnv,
  body : Module,
  aliases : Map[String, Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> Type raise TypeError {
  let scope_env = clone_env(env)
  let mut last = Type::Unit
  for stmt in body.stmts {
    match stmt {
      Stmt::Let(rec~, name~, expr~) => {
        let scheme = type_let_expr(
          scope_env, rec, name, expr, aliases, effects, allow_effect,
        )
        scope_env.set_scheme(name, scheme)
        last = scheme.ty
      }
      Stmt::EnumDef(name~, params~, ctors~) => {
        register_enum_def(scope_env, name, params, ctors)
        last = Type::Unit
      }
      Stmt::TypeAlias(name~, params~, target~) => {
        register_type_alias(scope_env, name, params, target)
        last = Type::Unit
      }
      Stmt::Expr(expr~) =>
        last = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
      Stmt::Flake(_) => last = Type::Unit
      Stmt::Alias(name~, target~) => {
        match target {
          AliasTarget::Module(_) => ()
          AliasTarget::Name(target_name) =>
            match scope_env.get_scheme(target_name) {
              Some(scheme) => scope_env.set_scheme(name, scheme)
              None => raise TypeError::UnknownName(target_name)
            }
        }
        last = Type::Unit
      }
      Stmt::Import(..) => last = Type::Unit
      Stmt::Test(name~, body~) => {
        let _ = name
        let _ = type_block(scope_env, body, aliases, effects, allow_effect)
        last = Type::Unit
      }
    }
  }
  last
}

///|
fn type_call(
  env : TypeEnv,
  name : String,
  args : Array[CallArg],
  aliases : Map[String, Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> Type raise TypeError {
  match env.get(name) {
    Some(ty) =>
      match ty {
        Type::Func(params~, ret~, effects=fn_effects) => {
          check_call_args(env, params, args, aliases, effects, allow_effect)
          require_effects(env, effects, fn_effects)
          ret
        }
        _ => raise TypeError::BadCall(name)
      }
    None =>
      match env.get_ctor(name) {
        Some(info) => {
          let pos_args = extract_positional_args(args, name)
          let inst = instantiate_ctor(env, info)
          match inst.payload {
            Type::Unit =>
              if pos_args.length() != 0 {
                raise TypeError::BadCall(name)
              }
            Type::Tuple(items) =>
              if pos_args.length() != items.length() {
                raise TypeError::BadCall(name)
              } else {
                for i in 0..<items.length() {
                  let arg_ty = type_expr_eff(
                    env,
                    pos_args[i],
                    aliases,
                    effects,
                    allow_effect,
                  )
                  if not(type_equal(env, arg_ty, items[i])) {
                    raise TypeError::Mismatch(expected=items[i], actual=arg_ty)
                  }
                }
              }
            _ =>
              if pos_args.length() != 1 {
                raise TypeError::BadCall(name)
              } else {
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, inst.payload)) {
                  raise TypeError::Mismatch(
                    expected=inst.payload,
                    actual=arg_ty,
                  )
                }
              }
          }
          inst.ret
        }
        None =>
          if is_ctor_name(name) {
            let pos_args = extract_positional_args(args, name)
            let field_ty = if pos_args.length() == 0 {
              Type::Unit
            } else if pos_args.length() == 1 {
              type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
            } else {
              let tys : Array[Type] = []
              for arg in pos_args {
                tys.push(
                  type_expr_eff(env, arg, aliases, effects, allow_effect),
                )
              }
              Type::Tuple(tys)
            }
            let map : Map[String, Type] = {}
            map[name] = field_ty
            Type::Variant(map)
          } else {
            match name {
              "path" => {
                let pos_args = extract_positional_args(args, "path")
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("path")
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=arg_ty,
                  )
                }
                Type::Path
              }
              "addr" => {
                let pos_args = extract_positional_args(args, "addr")
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("addr")
                }
                match pos_args[0] {
                  Expr::String(s) =>
                    match env.get_addr_type(s) {
                      Some(ty) => ty
                      None => raise TypeError::UnknownName("addr:" + s)
                    }
                  _ => raise TypeError::BadCall("addr")
                }
              }
              "sh" => {
                let pos_args = extract_positional_args(args, "sh")
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("sh")
                }
                require_effects(env, effects, builtin_effects("sh"))
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("sh")
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=arg_ty,
                  )
                }
                Type::Unit
              }
              "array_builder" => {
                let pos_args = extract_positional_args(args, "array_builder")
                if pos_args.length() != 0 {
                  raise TypeError::BadCall("array_builder")
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("array_builder")
                }
                let elem = fresh_type_var(env)
                Type::ArrayBuilder(elem)
              }
              "array_builder_push" => {
                let pos_args = extract_positional_args(
                  args, "array_builder_push",
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("array_builder_push")
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("array_builder_push")
                }
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let value_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, builder_ty, Type::ArrayBuilder(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::ArrayBuilder(elem_ty),
                    actual=builder_ty,
                  )
                }
                if not(type_equal(env, value_ty, elem_ty)) {
                  raise TypeError::Mismatch(expected=elem_ty, actual=value_ty)
                }
                Type::Unit
              }
              "array_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "array_builder_freeze",
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("array_builder_freeze")
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("array_builder_freeze")
                }
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, builder_ty, Type::ArrayBuilder(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::ArrayBuilder(elem_ty),
                    actual=builder_ty,
                  )
                }
                Type::Array(elem_ty)
              }
              "map_builder" => {
                let pos_args = extract_positional_args(args, "map_builder")
                if pos_args.length() != 0 {
                  raise TypeError::BadCall("map_builder")
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("map_builder")
                }
                let value = fresh_type_var(env)
                Type::MapBuilder(value)
              }
              "map_builder_set" => {
                let pos_args = extract_positional_args(args, "map_builder_set")
                if pos_args.length() != 3 {
                  raise TypeError::BadCall("map_builder_set")
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("map_builder_set")
                }
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let key_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, key_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=key_ty,
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, builder_ty, Type::MapBuilder(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::MapBuilder(elem_ty),
                    actual=builder_ty,
                  )
                }
                if not(type_equal(env, value_ty, elem_ty)) {
                  raise TypeError::Mismatch(expected=elem_ty, actual=value_ty)
                }
                Type::Unit
              }
              "map_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "map_builder_freeze",
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("map_builder_freeze")
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed("map_builder_freeze")
                }
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, builder_ty, Type::MapBuilder(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::MapBuilder(elem_ty),
                    actual=builder_ty,
                  )
                }
                Type::Map(elem_ty)
              }
              "array_length" => {
                let pos_args = extract_positional_args(args, "array_length")
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("array_length")
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, array_ty, Type::Array(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::Array(elem_ty),
                    actual=array_ty,
                  )
                }
                Type::Int
              }
              "array_get" => {
                let pos_args = extract_positional_args(args, "array_get")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("array_get")
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let index_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, index_ty, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=index_ty)
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, array_ty, Type::Array(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::Array(elem_ty),
                    actual=array_ty,
                  )
                }
                elem_ty
              }
              "map_get" => {
                let pos_args = extract_positional_args(args, "map_get")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("map_get")
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let key_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, key_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=key_ty,
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, map_ty, Type::Map(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=Type::Map(elem_ty),
                    actual=map_ty,
                  )
                }
                elem_ty
              }
              "string_length" => {
                let pos_args = extract_positional_args(args, "string_length")
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("string_length")
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=arg_ty,
                  )
                }
                Type::Int
              }
              "string_char_code_at" => {
                let pos_args = extract_positional_args(
                  args, "string_char_code_at",
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("string_char_code_at")
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let index_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=str_ty,
                  )
                }
                if not(type_equal(env, index_ty, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=index_ty)
                }
                Type::Int
              }
              "string_substring" => {
                let pos_args = extract_positional_args(args, "string_substring")
                if pos_args.length() != 3 {
                  raise TypeError::BadCall("string_substring")
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let start_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let end_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=str_ty,
                  )
                }
                if not(type_equal(env, start_ty, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=start_ty)
                }
                if not(type_equal(env, end_ty, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=end_ty)
                }
                Type::String
              }
              "string_concat" => {
                let pos_args = extract_positional_args(args, "string_concat")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("string_concat")
                }
                let left_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let right_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, left_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=left_ty,
                  )
                }
                if not(type_equal(env, right_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=right_ty,
                  )
                }
                Type::String
              }
              "string_equals" => {
                let pos_args = extract_positional_args(args, "string_equals")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("string_equals")
                }
                let left_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let right_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, left_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=left_ty,
                  )
                }
                if not(type_equal(env, right_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=right_ty,
                  )
                }
                Type::Bool
              }
              "__add" => {
                let pos_args = extract_positional_args(args, "__add")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("__add")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=a)
                }
                if not(type_equal(env, b, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=b)
                }
                Type::Int
              }
              "__sub" => {
                let pos_args = extract_positional_args(args, "__sub")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("__sub")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=a)
                }
                if not(type_equal(env, b, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=b)
                }
                Type::Int
              }
              "__mul" => {
                let pos_args = extract_positional_args(args, "__mul")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("__mul")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=a)
                }
                if not(type_equal(env, b, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=b)
                }
                Type::Int
              }
              "__div" => {
                let pos_args = extract_positional_args(args, "__div")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("__div")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=a)
                }
                if not(type_equal(env, b, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=b)
                }
                Type::Int
              }
              "__eq" => {
                let pos_args = extract_positional_args(args, "__eq")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("__eq")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=a)
                }
                if not(type_equal(env, b, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=b)
                }
                Type::Bool
              }
              "__lt" => {
                let pos_args = extract_positional_args(args, "__lt")
                if pos_args.length() != 2 {
                  raise TypeError::BadCall("__lt")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=a)
                }
                if not(type_equal(env, b, Type::Int)) {
                  raise TypeError::Mismatch(expected=Type::Int, actual=b)
                }
                Type::Bool
              }
              "__assert" => {
                let pos_args = extract_positional_args(args, "__assert")
                if pos_args.length() != 1 {
                  raise TypeError::BadCall("__assert")
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, Type::Bool)) {
                  raise TypeError::Mismatch(expected=Type::Bool, actual=a)
                }
                Type::Unit
              }
              "record_set" => {
                let pos_args = extract_positional_args(args, "record_set")
                if pos_args.length() != 3 {
                  raise TypeError::BadCall("record_set")
                }
                let record_ty = normalize_type(
                  env,
                  type_expr_eff(
                    env,
                    pos_args[0],
                    aliases,
                    effects,
                    allow_effect,
                  ),
                )
                let field_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, field_ty, Type::String)) {
                  raise TypeError::Mismatch(
                    expected=Type::String,
                    actual=field_ty,
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                match record_ty {
                  Type::Record(fields) =>
                    match pos_args[1] {
                      Expr::String(name) =>
                        match fields.get(name) {
                          Some(expect) =>
                            if not(type_equal(env, expect, value_ty)) {
                              raise TypeError::Mismatch(
                                expected=expect,
                                actual=value_ty,
                              )
                            }
                          None => raise TypeError::BadCall("record_set")
                        }
                      _ => ()
                    }
                  _ => raise TypeError::BadCall("record_set")
                }
                record_ty
              }
              _ => raise TypeError::BadCall(name)
            }
          }
      }
  }
}

///|
fn is_non_expansive_expr(
  env : TypeEnv,
  expr : Expr,
  aliases : Map[String, Ref],
) -> Bool {
  match expr {
    Expr::Int(_) => true
    Expr::Bool(_) => true
    Expr::String(_) => true
    Expr::Ident(name) => not(has_alias_prefix(name, aliases))
    Expr::Tuple(items) => {
      let mut ok = true
      for item in items {
        if not(is_non_expansive_expr(env, item, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    Expr::Record(fields) => {
      let mut ok = true
      for field in fields {
        if not(is_non_expansive_expr(env, field.expr, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    Expr::Array(items) => {
      let mut ok = true
      for item in items {
        if not(is_non_expansive_expr(env, item, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    Expr::Map(fields) => {
      let mut ok = true
      for field in fields {
        if not(is_non_expansive_expr(env, field.expr, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    Expr::Fn(..) => true
    Expr::Call(name~, args~) =>
      if has_alias_prefix(name, aliases) {
        false
      } else if is_ctor_name(name) {
        let mut ok = true
        for arg in args {
          if not(is_non_expansive_expr(env, arg.expr, aliases)) {
            ok = false
            break
          }
        }
        ok
      } else {
        false
      }
    _ => false
  }
}

///|
fn type_let_expr(
  env : TypeEnv,
  rec : Bool,
  name : String,
  expr : Expr,
  aliases : Map[String, Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> TypeScheme raise TypeError {
  if rec {
    match expr {
      Expr::Fn(params~, ret~, effects=fn_effects, body~) =>
        match ret {
          None => raise TypeError::BadRec("missing return type")
          Some(r) => {
            let normalized_effects = normalize_effects(fn_effects)
            let fn_ty = normalize_type(
              env,
              Type::Func(params~, ret=r, effects=normalized_effects),
            )
            env.set(name, fn_ty)
            let ty = type_expr_eff(
              env,
              Expr::Fn(params~, ret~, effects=normalized_effects, body~),
              aliases,
              effects,
              allow_effect,
            )
            if not(type_equal(env, ty, fn_ty)) {
              raise TypeError::Mismatch(expected=fn_ty, actual=ty)
            }
            TypeScheme::{ vars: [], effect_vars: [], ty: fn_ty }
          }
        }
      _ => raise TypeError::BadRec("expected fn")
    }
  } else {
    let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
    if allow_effect {
      if is_non_expansive_expr(env, expr, aliases) {
        generalize(env, ty)
      } else {
        let resolved = resolve_type(env, ty)
        let normalized = normalize_type(env, resolved)
        TypeScheme::{ vars: [], effect_vars: [], ty: normalized }
      }
    } else {
      generalize(env, ty)
    }
  }
}

///|
priv struct ArgType {
  label : String?
  ty : Type
}

///|
fn extract_positional_args(
  args : Array[CallArg],
  name : String,
) -> Array[Expr] raise TypeError {
  let out : Array[Expr] = []
  for arg in args {
    match arg.label {
      Some(_) => raise TypeError::BadCall(name)
      None => out.push(arg.expr)
    }
  }
  out
}

///|
fn check_call_args(
  env : TypeEnv,
  params : Array[FuncParam],
  args : Array[CallArg],
  aliases : Map[String, Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> Unit raise TypeError {
  let arg_types : Array[ArgType] = []
  for arg in args {
    let ty = type_expr_eff(env, arg.expr, aliases, effects, allow_effect)
    arg_types.push(ArgType::{ label: arg.label, ty })
  }
  let positional : Array[FuncParam] = []
  for param in params {
    if param.label == ParamLabel::Positional {
      positional.push(param)
    }
  }
  let mut pos_index = 0
  let used_labels : Map[String, Bool] = {}
  for arg in arg_types {
    match arg.label {
      None => {
        if pos_index >= positional.length() {
          raise TypeError::BadCall("too many positional args")
        }
        let param = positional[pos_index]
        pos_index += 1
        if not(type_equal(env, param.ty, arg.ty)) {
          raise TypeError::Mismatch(expected=param.ty, actual=arg.ty)
        }
      }
      Some(label) => {
        if used_labels.contains(label) {
          raise TypeError::BadCall("duplicate label: " + label)
        }
        let mut found : FuncParam? = None
        for param in params {
          if param.label != ParamLabel::Positional && param.name == label {
            found = Some(param)
            break
          }
        }
        match found {
          Some(param) => {
            used_labels[label] = true
            if not(type_equal(env, param.ty, arg.ty)) {
              raise TypeError::Mismatch(expected=param.ty, actual=arg.ty)
            }
          }
          None => raise TypeError::BadCall("unknown label: " + label)
        }
      }
    }
  }
  if pos_index != positional.length() {
    raise TypeError::BadCall("missing positional args")
  }
  for param in params {
    if param.label == ParamLabel::Required &&
      not(used_labels.contains(param.name)) {
      raise TypeError::BadCall("missing label: " + param.name)
    }
  }
}

///|
fn normalize_type(env : TypeEnv, ty : Type) -> Type raise TypeError {
  let resolved = resolve_type(env, ty)
  normalize_type_inner(env, resolved, {})
}

///|
fn normalize_type_inner(
  env : TypeEnv,
  ty : Type,
  visiting : Map[String, Bool],
) -> Type raise TypeError {
  match ty {
    Type::Named(name~, args~) => {
      let normalized_args : Array[Type] = []
      for arg in args {
        normalized_args.push(normalize_type_inner(env, arg, visiting))
      }
      if visiting.contains(name) {
        match env.get_enum_def(name) {
          Some(_) => Type::Named(name~, args=normalized_args)
          None => raise TypeError::BadTypeDef("recursive type: " + name)
        }
      } else {
        let next : Map[String, Bool] = {}
        for key, val in visiting {
          next[key] = val
        }
        next[name] = true
        match env.get_type_alias(name) {
          Some(type_alias) => {
            if type_alias.params.length() != normalized_args.length() {
              raise TypeError::BadTypeDef("type arity: " + name)
            }
            let mapping : Map[String, Type] = {}
            for i in 0..<type_alias.params.length() {
              mapping[type_alias.params[i]] = normalized_args[i]
            }
            let substituted = substitute_type(type_alias.target, mapping)
            normalize_type_inner(env, substituted, next)
          }
          None =>
            match env.get_enum_def(name) {
              Some(def) => {
                if def.params.length() != normalized_args.length() {
                  raise TypeError::BadTypeDef("type arity: " + name)
                }
                let mapping : Map[String, Type] = {}
                for i in 0..<def.params.length() {
                  mapping[def.params[i]] = normalized_args[i]
                }
                let ctor_map : Map[String, Type] = {}
                for ctor in def.ctors {
                  let base_payload = if ctor.args.length() == 0 {
                    Type::Unit
                  } else if ctor.args.length() == 1 {
                    ctor.args[0]
                  } else {
                    Type::Tuple(ctor.args)
                  }
                  let substituted = substitute_type(base_payload, mapping)
                  ctor_map[ctor.name] = normalize_type_inner(
                    env, substituted, next,
                  )
                }
                Type::Variant(ctor_map)
              }
              None => raise TypeError::UnknownType(name)
            }
        }
      }
    }
    Type::Tuple(items) => {
      let out : Array[Type] = []
      for item in items {
        out.push(normalize_type_inner(env, item, visiting))
      }
      Type::Tuple(out)
    }
    Type::Record(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = normalize_type_inner(env, item, visiting)
      }
      Type::Record(out)
    }
    Type::Array(inner) =>
      Type::Array(normalize_type_inner(env, inner, visiting))
    Type::Map(inner) => Type::Map(normalize_type_inner(env, inner, visiting))
    Type::ArrayBuilder(inner) =>
      Type::ArrayBuilder(normalize_type_inner(env, inner, visiting))
    Type::MapBuilder(inner) =>
      Type::MapBuilder(normalize_type_inner(env, inner, visiting))
    Type::Variant(fields) => {
      let out : Map[String, Type] = {}
      for name, item in fields {
        out[name] = normalize_type_inner(env, item, visiting)
      }
      Type::Variant(out)
    }
    Type::Param(_) => ty
    Type::Var(_) => ty
    Type::Func(params~, ret~, effects~) => {
      let out : Array[FuncParam] = []
      for param in params {
        out.push(FuncParam::{
          name: param.name,
          label: param.label,
          ty: normalize_type_inner(env, param.ty, visiting),
        })
      }
      Type::Func(
        params=out,
        ret=normalize_type_inner(env, ret, visiting),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn type_equal(env : TypeEnv, a : Type, b : Type) -> Bool raise TypeError {
  unify_types(env, a, b)
}

///|
/// Completion helper: true if param type can accept receiver type.
pub fn completion_param_matches(
  env : TypeEnv,
  receiver : Type,
  param : Type,
) -> Bool {
  let recv = normalize_type(env, receiver) catch { _ => receiver }
  let param_ty = normalize_type(env, param) catch { _ => param }
  match param_ty {
    Type::Var(_) | Type::Param(_) => true
    _ =>
      match recv {
        Type::Var(_) | Type::Param(_) => true
        _ => type_equal(env, recv, param_ty) catch { _ => false }
      }
  }
}

///|
fn unify_types(env : TypeEnv, a : Type, b : Type) -> Bool raise TypeError {
  let left = resolve_type(env, a)
  let right = resolve_type(env, b)
  match (left, right) {
    (Type::Named(name=an, args=aa), Type::Named(name=bn, args=bb)) =>
      if an == bn {
        if aa.length() != bb.length() {
          false
        } else {
          let mut ok = true
          for i in 0..<aa.length() {
            if not(unify_types(env, aa[i], bb[i])) {
              ok = false
              break
            }
          }
          ok
        }
      } else {
        let nl = normalize_type(env, left)
        let nr = normalize_type(env, right)
        unify_types(env, nl, nr)
      }
    (Type::Var(id), t) => bind_var(env, id, t)
    (t, Type::Var(id)) => bind_var(env, id, t)
    (Type::Param(a0), Type::Param(b0)) => a0 == b0
    (Type::Param(_), _) => false
    (_, Type::Param(_)) => false
    (Type::Named(..), _) => {
      let nl = normalize_type(env, left)
      unify_types(env, nl, right)
    }
    (_, Type::Named(..)) => {
      let nr = normalize_type(env, right)
      unify_types(env, left, nr)
    }
    (Type::Int, Type::Int) => true
    (Type::Bool, Type::Bool) => true
    (Type::String, Type::String) => true
    (Type::Path, Type::Path) => true
    (Type::Unit, Type::Unit) => true
    (Type::Tuple(xs), Type::Tuple(ys)) =>
      if xs.length() != ys.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<xs.length() {
          if not(unify_types(env, xs[i], ys[i])) {
            ok = false
            break
          }
        }
        ok
      }
    (Type::Record(ax), Type::Record(bx)) =>
      if ax.length() != bx.length() {
        false
      } else {
        let mut ok = true
        for name, ty in ax {
          match bx.get(name) {
            Some(other) =>
              if not(unify_types(env, ty, other)) {
                ok = false
                break
              }
            None => {
              ok = false
              break
            }
          }
        }
        ok
      }
    (Type::Array(ae), Type::Array(be)) => unify_types(env, ae, be)
    (Type::Map(av), Type::Map(bv)) => unify_types(env, av, bv)
    (Type::ArrayBuilder(ae), Type::ArrayBuilder(be)) => unify_types(env, ae, be)
    (Type::MapBuilder(av), Type::MapBuilder(bv)) => unify_types(env, av, bv)
    (Type::Variant(ax), Type::Variant(bx)) =>
      if ax.length() != bx.length() {
        false
      } else {
        let mut ok = true
        for name, ty in ax {
          match bx.get(name) {
            Some(other) =>
              if not(unify_types(env, ty, other)) {
                ok = false
                break
              }
            None => {
              ok = false
              break
            }
          }
        }
        ok
      }
    (
      Type::Func(params=pa, ret=ra, effects=ea),
      Type::Func(params=pb, ret=rb, effects=eb),
    ) =>
      if pa.length() != pb.length() {
        false
      } else if not(unify_effects(env, ea, eb)) {
        false
      } else if not(unify_types(env, ra, rb)) {
        false
      } else {
        let mut ok = true
        for i in 0..<pa.length() {
          if not(param_unify(env, pa[i], pb[i])) {
            ok = false
            break
          }
        }
        ok
      }
    _ => false
  }
}

///|
fn param_unify(
  env : TypeEnv,
  a : FuncParam,
  b : FuncParam,
) -> Bool raise TypeError {
  if a.label != b.label {
    return false
  }
  if a.label != ParamLabel::Positional && a.name != b.name {
    return false
  }
  unify_types(env, a.ty, b.ty)
}

///|
fn bind_var(env : TypeEnv, id : Int, ty : Type) -> Bool {
  if occurs_in(env, id, ty) {
    false
  } else {
    env.subs[id] = ty
    true
  }
}

///|
fn occurs_in(env : TypeEnv, id : Int, ty : Type) -> Bool {
  match resolve_type(env, ty) {
    Type::Var(other) => other == id
    Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    Type::Array(inner) => occurs_in(env, id, inner)
    Type::Map(inner) => occurs_in(env, id, inner)
    Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    Type::Named(name=_, args~) => {
      let mut found = false
      for arg in args {
        if occurs_in(env, id, arg) {
          found = true
          break
        }
      }
      found
    }
    Type::Func(params~, ret~, effects=_) => {
      let mut found = occurs_in(env, id, ret)
      if not(found) {
        for param in params {
          if occurs_in(env, id, param.ty) {
            found = true
            break
          }
        }
      }
      found
    }
    _ => false
  }
}

///|
fn has_alias_prefix(name : String, aliases : Map[String, Ref]) -> Bool {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return false
  }
  let buf = StringBuilder::new()
  for i in 0..<dot {
    buf.write_char(chars[i])
  }
  let prefix = buf.to_string()
  aliases.contains(prefix)
}
