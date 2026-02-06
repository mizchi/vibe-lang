///|
/// @core.Type checking for xsh
suberror TypeError {
  UnknownName(name~ : String, span~ : @core.Span, suggestion~ : String?)
  UnknownType(name~ : String, span~ : @core.Span, suggestion~ : String?)
  Mismatch(
    expected~ : @core.Type,
    actual~ : @core.Type,
    span~ : @core.Span,
    context~ : String?
  )
  BadCall(message~ : String, span~ : @core.Span)
  BadRec(message~ : String, span~ : @core.Span)
  BadMatch(message~ : String, span~ : @core.Span)
  NonExhaustiveMatch(span~ : @core.Span)
  BadTypeDef(message~ : String, span~ : @core.Span)
  EffectNotAllowed(name~ : String, span~ : @core.Span)
} derive(Show, Eq)

///|
// Global counter to avoid type var id collisions across env forks.
let global_next_type_var : Ref[Int] = @ref.new(0)

///|
fn suggestion_hint(suggestion : String?) -> String? {
  match suggestion {
    Some(name) => Some("did you mean `" + name + "`?")
    None => None
  }
}

///|
pub fn TypeError::diagnostic(self : TypeError) -> @core.Diagnostic {
  match self {
    TypeError::UnknownName(name~, span~, suggestion~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "unknown name: " + name,
        span: Some(span),
        hint: suggestion_hint(suggestion),
        note: None,
      }
    TypeError::UnknownType(name~, span~, suggestion~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "unknown type: " + name,
        span: Some(span),
        hint: suggestion_hint(suggestion),
        note: None,
      }
    TypeError::Mismatch(expected~, actual~, span~, context~) => {
      let message = match context {
        Some(ctx) => "type mismatch (" + ctx + ")"
        None => "type mismatch"
      }
      @core.Diagnostic::{
        stage: "type",
        message,
        span: Some(span),
        hint: None,
        note: Some(
          "expected: " +
          expected.to_string() +
          "\nactual: " +
          actual.to_string(),
        ),
      }
    }
    TypeError::BadCall(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: format_bad_call(message),
        span: Some(span),
        hint: None,
        note: None,
      }
    TypeError::BadRec(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: format_bad_rec(message),
        span: Some(span),
        hint: None,
        note: None,
      }
    TypeError::BadMatch(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: format_bad_match(message),
        span: Some(span),
        hint: None,
        note: None,
      }
    TypeError::NonExhaustiveMatch(span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "non-exhaustive match",
        span: Some(span),
        hint: None,
        note: None,
      }
    TypeError::BadTypeDef(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "type definition: " + message,
        span: Some(span),
        hint: None,
        note: None,
      }
    TypeError::EffectNotAllowed(name~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "effect not allowed: `" + name + "`",
        span: Some(span),
        hint: Some("wrap in `do { ... }` to allow side effects"),
        note: None,
      }
  }
}

///|
fn format_bad_call(message : String) -> String {
  match message {
    "missing positional args" => "not enough arguments"
    "too many positional args" => "too many arguments"
    _ =>
      if message.has_prefix("unknown label: ") ||
        message.has_prefix("duplicate label: ") ||
        message.has_prefix("missing label: ") {
        message
      } else {
        "unknown function: `" + message + "`"
      }
  }
}

///|
fn format_bad_rec(message : String) -> String {
  match message {
    "expected fn" => "`let rec` requires a `fn` expression"
    "missing return type" => "`let rec` requires a return type annotation"
    _ => message
  }
}

///|
fn format_bad_match(message : String) -> String {
  match message {
    "expected tuple" => "cannot destructure: value is not a tuple"
    "expected record" => "cannot destructure: value is not a record"
    "expected ctor variant" => "cannot destructure: value is not an enum"
    "empty match" => "`match` requires at least one arm"
    "tuple arity" => "tuple pattern has wrong number of elements"
    "ctor arity" => "constructor pattern has wrong number of arguments"
    _ =>
      if message.has_prefix("duplicate bind: ") {
        "duplicate binding: `" +
        message.to_array()[16:]
        .iter()
        .fold(init=StringBuilder::new(), fn(sb, c) {
          sb.write_char(c)
          sb
        })
        .to_string() +
        "`"
      } else {
        message
      }
  }
}

///|
fn TypeError::resolve_vars(self : TypeError, env : TypeEnv) -> TypeError {
  match self {
    TypeError::Mismatch(expected~, actual~, span~, context~) =>
      TypeError::Mismatch(
        expected=resolve_type(env, expected),
        actual=resolve_type(env, actual),
        span~,
        context~,
      )
    _ => self
  }
}

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
  ty : @core.Type
} derive(Show, Eq)

///|
pub struct TypeAlias {
  name : String
  params : Array[String]
  target : @core.Type
} derive(Show, Eq)

///|
pub struct TypeEnv {
  bindings : Map[String, TypeScheme]
  addr_types : Map[String, @core.Type]
  enum_defs : Map[String, EnumDef]
  type_aliases : Map[String, TypeAlias]
  ctor_index : Map[String, CtorInfo]
  purities : Map[String, Bool]
  expr_types : Map[String, @core.Type]
  num_vars : Map[Int, Bool]
  mut next_var : Int
  mut next_effect_var : Int
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
  span : @core.Span,
) -> Unit raise TypeError {
  if scope.allow_all {
    return ()
  }
  let scope_set = effect_set_from_scope(scope)
  let required_set = effect_set_from_atoms(env, effects)
  match ensure_effects_allowed(env, scope_set, required_set) {
    Some(name) => raise TypeError::EffectNotAllowed(name~, span~)
    None => ()
  }
}

///|
fn builtin_effects(name : String) -> Array[@core.EffectAtom] {
  match name {
    "sh" => [@core.EffectAtom::Const("Stdout")]
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
    type_aliases: {},
    ctor_index: {},
    purities: {},
    expr_types: {},
    num_vars: {},
    next_var: 0,
    next_effect_var: 0,
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
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    purities: self.purities.copy(),
    expr_types: self.expr_types,
    num_vars: self.num_vars.copy(),
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
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
    type_aliases: self.type_aliases.copy(),
    ctor_index: self.ctor_index.copy(),
    purities: self.purities.copy(),
    expr_types: self.expr_types,
    num_vars: self.num_vars.copy(),
    next_var: self.next_var,
    next_effect_var: self.next_effect_var,
    subs: self.subs.copy(),
    effect_subs: self.effect_subs.copy(),
  }
}

///|
pub fn TypeEnv::set(self : TypeEnv, name : String, ty : @core.Type) -> Unit {
  self.bindings[name] = TypeScheme::{
    vars: [],
    num_vars: [],
    effect_vars: [],
    ty,
  }
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
pub fn TypeEnv::set_addr_type(
  self : TypeEnv,
  addr : String,
  ty : @core.Type,
) -> Unit {
  self.addr_types[addr] = ty
}

///|
pub fn type_check(ast : @core.Module) -> TypeEnv raise TypeError {
  type_check_with_aliases(ast, {})
}

///|
/// @core.Type check with import aliases (qualified names treated as external).
pub fn type_check_with_aliases(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> TypeEnv raise TypeError {
  let env = TypeEnv::new()
  ensure_prelude_option(env)
  ensure_prelude_functions(env, aliases)
  type_check_stmts(env, ast.stmts, aliases, effect_scope_all(), false) catch {
    e => raise e.resolve_vars(env)
  }
}

///|
pub fn type_check_with_env(
  env : TypeEnv,
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> TypeEnv raise TypeError {
  ensure_prelude_option(env)
  ensure_prelude_functions(env, aliases)
  type_check_stmts(env, ast.stmts, aliases, effect_scope_all(), false) catch {
    e => raise e.resolve_vars(env)
  }
}

///|
fn type_check_stmts(
  env : TypeEnv,
  stmts : Array[@core.Stmt],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> TypeEnv raise TypeError {
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let scheme = type_let_expr(
          env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        env.set_scheme(name, scheme)
        let info = purity_for_let(env, rec, name, expr)
        env.set_purity(name, info.value)
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        register_enum_def(env, name, params, ctors, span)
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        register_type_alias(env, name, params, target, span)
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        let _ = type_expr_eff(env, expr, aliases, effects, allow_effect)

      }
      @core.Stmt::Flake(raw~, span~) => {
        let _ = raw
        let _ = span

      }
      @core.Stmt::Alias(name~, target~, span~) =>
        match target {
          @core.AliasTarget::Module(_) => ()
          @core.AliasTarget::Name(target_name) =>
            match env.get_scheme(target_name) {
              Some(scheme) => env.set_scheme(name, scheme)
              None =>
                raise TypeError::UnknownName(
                  name=target_name,
                  span~,
                  suggestion=find_name_suggestion(env, aliases, target_name),
                )
            }
        }
      @core.Stmt::Import(..) => ()
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_check_stmts(
          clone_env(env),
          body.stmts,
          aliases,
          effects,
          allow_effect,
        )

      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        let scheme = TypeScheme::{ vars: [], num_vars: [], effect_vars: [], ty }
        env.set_scheme(name, scheme)
        env.set_purity(name, false)
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(env, pat, ty)
        for name, bound_ty in bindings {
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            ty: bound_ty,
          }
          env.set_scheme(name, scheme)
          env.set_purity(name, true)
        }
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        match env.get_scheme(name) {
          Some(scheme) => {
            let expected = instantiate_scheme(env, scheme)
            if not(type_equal(env, expected, ty)) {
              raise TypeError::Mismatch(
                expected~,
                actual=ty,
                span~,
                context=Some("assignment"),
              )
            }
          }
          None =>
            raise TypeError::UnknownName(
              name~,
              span~,
              suggestion=find_name_suggestion(env, aliases, name),
            )
        }
      }
    }
  }
  env
}

///|
fn clone_env(env : TypeEnv) -> TypeEnv {
  env.fork_for_check()
}

///|
fn ensure_unique_params(
  params : Array[String],
  span : @core.Span,
) -> Unit raise TypeError {
  let seen : Map[String, Bool] = {}
  for param in params {
    if seen.contains(param) {
      raise TypeError::BadTypeDef(
        message="duplicate type param: " + param,
        span~,
      )
    }
    seen[param] = true
  }
}

///|
fn simple_distance(a : String, b : String) -> Int {
  let a_chars = a.to_array()
  let b_chars = b.to_array()
  let min = if a_chars.length() < b_chars.length() {
    a_chars.length()
  } else {
    b_chars.length()
  }
  let mut diff = if a_chars.length() > b_chars.length() {
    a_chars.length() - b_chars.length()
  } else {
    b_chars.length() - a_chars.length()
  }
  for i in 0..<min {
    if a_chars[i] != b_chars[i] {
      diff += 1
    }
  }
  diff
}

///|
fn best_suggestion(candidates : Array[String], name : String) -> String? {
  let mut best : String? = None
  let mut best_score = 9999
  for cand in candidates {
    let score = simple_distance(name, cand)
    if score < best_score {
      best_score = score
      best = Some(cand)
    }
  }
  if best_score <= 3 {
    best
  } else {
    None
  }
}

///|
fn unknown_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn span_key(span : @core.Span) -> String {
  span.start.to_string() + ":" + span.end.to_string()
}

///|
fn find_name_suggestion(
  env : TypeEnv,
  aliases : Map[String, @core.Ref],
  name : String,
) -> String? {
  let candidates : Array[String] = []
  for key, _ in env.bindings {
    candidates.push(key)
  }
  for key, _ in env.ctor_index {
    candidates.push(key)
  }
  for key, _ in aliases {
    candidates.push(key)
  }
  best_suggestion(candidates, name)
}

///|
fn find_type_suggestion(env : TypeEnv, name : String) -> String? {
  let candidates : Array[String] = [
    "Int", "Float", "Double", "Bool", "String", "@core.Path", "Unit", "Array", "Map",
    "ArrayBuilder", "MapBuilder",
  ]
  for key, _ in env.enum_defs {
    candidates.push(key)
  }
  for key, _ in env.type_aliases {
    candidates.push(key)
  }
  best_suggestion(candidates, name)
}

///|
pub fn ensure_prelude_option(env : TypeEnv) -> Unit raise TypeError {
  if env.get_enum_def("Option") is Some(_) {
    return
  }
  let span = @core.Span::empty(0)
  let ctors : Array[@core.TypeCtor] = [
    @core.TypeCtor::{ name: "Some", args: [@core.Type::Param("T")], span },
    @core.TypeCtor::{ name: "None", args: [], span },
  ]
  register_enum_def(env, "Option", ["T"], ctors, span)
}

///|
pub fn ensure_prelude_functions(
  env : TypeEnv,
  aliases : Map[String, @core.Ref],
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
fn fresh_type_var(env : TypeEnv) -> @core.Type {
  let id = global_next_type_var.val
  global_next_type_var.val += 1
  if env.next_var <= id {
    env.next_var = id + 1
  }
  @core.Type::Var(id)
}

///|
fn mark_num_var(env : TypeEnv, id : Int) -> Unit {
  env.num_vars[id] = true
}

///|
fn is_num_var(env : TypeEnv, id : Int) -> Bool {
  env.num_vars.contains(id)
}

///|
fn fresh_num_var(env : TypeEnv) -> @core.Type {
  let ty = fresh_type_var(env)
  match ty {
    @core.Type::Var(id) => mark_num_var(env, id)
    _ => ()
  }
  ty
}

///|
fn fresh_effect_var(env : TypeEnv) -> String {
  let id = env.next_effect_var
  env.next_effect_var += 1
  "$e" + id.to_string()
}

///|
fn instantiate_scheme(env : TypeEnv, scheme : TypeScheme) -> @core.Type {
  let mapping : Map[Int, @core.Type] = {}
  for id in scheme.vars {
    if scheme.num_vars.contains(id) {
      mapping[id] = fresh_num_var(env)
    } else {
      mapping[id] = fresh_type_var(env)
    }
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
fn resolve_type(env : TypeEnv, ty : @core.Type) -> @core.Type {
  if env.subs.is_empty() {
    ty
  } else {
    match ty {
      @core.Type::Var(id) =>
        match env.subs.get(id) {
          Some(t) => {
            let resolved = resolve_type(env, t)
            env.subs[id] = resolved
            resolved
          }
          None => ty
        }
      @core.Type::Tuple(items) => {
        let out : Array[@core.Type] = []
        for item in items {
          out.push(resolve_type(env, item))
        }
        @core.Type::Tuple(out)
      }
      @core.Type::Record(fields) => {
        let out : Map[String, @core.Type] = {}
        for name, item in fields {
          out[name] = resolve_type(env, item)
        }
        @core.Type::Record(out)
      }
      @core.Type::Array(inner) => @core.Type::Array(resolve_type(env, inner))
      @core.Type::Map(inner) => @core.Type::Map(resolve_type(env, inner))
      @core.Type::ArrayBuilder(inner) =>
        @core.Type::ArrayBuilder(resolve_type(env, inner))
      @core.Type::MapBuilder(inner) =>
        @core.Type::MapBuilder(resolve_type(env, inner))
      @core.Type::Variant(fields) => {
        let out : Map[String, @core.Type] = {}
        for name, item in fields {
          out[name] = resolve_type(env, item)
        }
        @core.Type::Variant(out)
      }
      @core.Type::Named(name~, args~) => {
        let out : Array[@core.Type] = []
        for arg in args {
          out.push(resolve_type(env, arg))
        }
        @core.Type::Named(name~, args=out)
      }
      @core.Type::Func(params~, ret~, effects~) => {
        let out : Array[@core.FuncParam] = []
        for param in params {
          out.push(@core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: resolve_type(env, param.ty),
          })
        }
        @core.Type::Func(params=out, ret=resolve_type(env, ret), effects~)
      }
      _ => ty
    }
  }
}

///|
fn substitute_type_vars(
  ty : @core.Type,
  subs : Map[Int, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Var(id) =>
      match subs.get(id) {
        Some(t) => t
        None => ty
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type_vars(item, subs))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_vars(item, subs)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_vars(inner, subs))
    @core.Type::Map(inner) => @core.Type::Map(substitute_type_vars(inner, subs))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type_vars(inner, subs))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_type_vars(inner, subs))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_vars(item, subs)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type_vars(arg, subs))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_vars(param.ty, subs),
        })
      }
      @core.Type::Func(
        params=out,
        ret=substitute_type_vars(ret, subs),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn substitute_effect_vars(
  ty : @core.Type,
  subs : Map[String, String],
) -> @core.Type {
  match ty {
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_effect_vars(item, subs))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_effect_vars(item, subs)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_effect_vars(inner, subs))
    @core.Type::Map(inner) =>
      @core.Type::Map(substitute_effect_vars(inner, subs))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_effect_vars(inner, subs))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_effect_vars(inner, subs))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_effect_vars(item, subs)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_effect_vars(arg, subs))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_effect_vars(param.ty, subs),
        })
      }
      let eff_out : Array[@core.EffectAtom] = []
      for effect in effects {
        match effect {
          @core.EffectAtom::Const(_) => eff_out.push(effect)
          @core.EffectAtom::Var(name) =>
            match subs.get(name) {
              Some(mapped) => eff_out.push(@core.EffectAtom::Var(mapped))
              None => eff_out.push(effect)
            }
        }
      }
      @core.Type::Func(
        params=out,
        ret=substitute_effect_vars(ret, subs),
        effects=eff_out,
      )
    }
    _ => ty
  }
}

///|
fn substitute_type(
  ty : @core.Type,
  subs : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match subs.get(name) {
        Some(t) => t
        None => ty
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type(item, subs))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type(item, subs)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) => @core.Type::Array(substitute_type(inner, subs))
    @core.Type::Map(inner) => @core.Type::Map(substitute_type(inner, subs))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type(inner, subs))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_type(inner, subs))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type(item, subs)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type(arg, subs))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type(param.ty, subs),
        })
      }
      @core.Type::Func(params=out, ret=substitute_type(ret, subs), effects~)
    }
    _ => ty
  }
}

///|
fn instantiate_ctor(env : TypeEnv, info : CtorInfo) -> CtorInstance {
  let mapping : Map[String, @core.Type] = {}
  let args : Array[@core.Type] = []
  for param in info.params {
    let ty_var = fresh_type_var(env)
    mapping[param] = ty_var
    args.push(ty_var)
  }
  let payload = substitute_type(info.payload, mapping)
  let ret = @core.Type::Named(name=info.type_name, args~)
  { payload, ret }
}

///|
fn has_num_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        true
      } else {
        let mut found = false
        for arg in args {
          if has_num_type(arg) {
            found = true
            break
          }
        }
        found
      }
    @core.Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Array(inner)
    | @core.Type::Map(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::MapBuilder(inner) => has_num_type(inner)
    @core.Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Func(params~, ret~, ..) => {
      let mut found = false
      for param in params {
        if has_num_type(param.ty) {
          found = true
          break
        }
      }
      if found {
        true
      } else {
        has_num_type(ret)
      }
    }
    _ => false
  }
}

///|
fn replace_num_type(ty : @core.Type, num_var : @core.Type) -> @core.Type {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        num_var
      } else {
        let out : Array[@core.Type] = []
        for arg in args {
          out.push(replace_num_type(arg, num_var))
        }
        @core.Type::Named(name~, args=out)
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(replace_num_type(item, num_var))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, num_var)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(replace_num_type(inner, num_var))
    @core.Type::Map(inner) => @core.Type::Map(replace_num_type(inner, num_var))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(replace_num_type(inner, num_var))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(replace_num_type(inner, num_var))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, num_var)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: replace_num_type(param.ty, num_var),
        })
      }
      @core.Type::Func(params=out, ret=replace_num_type(ret, num_var), effects~)
    }
    _ => ty
  }
}

///|
fn record_expr_type(env : TypeEnv, span : @core.Span, ty : @core.Type) -> Unit {
  let resolved = resolve_type(env, ty)
  let normalized = normalize_type(env, resolved) catch { _ => resolved }
  env.expr_types[span_key(span)] = normalized
}

///|
fn register_enum_def(
  env : TypeEnv,
  name : String,
  params : Array[String],
  ctors : Array[@core.TypeCtor],
  span : @core.Span,
) -> Unit raise TypeError {
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  if ctors.is_empty() {
    raise TypeError::BadTypeDef(message="empty type: " + name, span~)
  }
  ensure_unique_params(params, span)
  env.set_enum_def(name, EnumDef::{ name, params, ctors })
  let ctor_map : Map[String, @core.Type] = {}
  for ctor in ctors {
    if ctor_map.contains(ctor.name) {
      raise TypeError::BadTypeDef(
        message="duplicate ctor: " + ctor.name,
        span=ctor.span,
      )
    }
    let payload = ctor_payload_type(env, ctor)
    ctor_map[ctor.name] = payload
  }
  for ctor_name, payload in ctor_map {
    if env.get_ctor(ctor_name) is Some(_) {
      raise TypeError::BadTypeDef(
        message="ctor already defined: " + ctor_name,
        span~,
      )
    }
    env.set_ctor(ctor_name, CtorInfo::{ type_name: name, params, payload })
  }
}

///|
fn register_type_alias(
  env : TypeEnv,
  name : String,
  params : Array[String],
  target : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  ensure_unique_params(params, span)
  let normalized = normalize_type(env, target)
  env.set_type_alias(name, TypeAlias::{ name, params, target: normalized })
}

///|
fn ctor_payload_type(
  env : TypeEnv,
  ctor : @core.TypeCtor,
) -> @core.Type raise TypeError {
  if ctor.args.length() == 0 {
    @core.Type::Unit
  } else if ctor.args.length() == 1 {
    normalize_type(env, ctor.args[0])
  } else {
    let items : Array[@core.Type] = []
    for arg in ctor.args {
      items.push(normalize_type(env, arg))
    }
    @core.Type::Tuple(items)
  }
}

///|
fn type_expr_eff(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let ty = match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Int
    }
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Float
    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Double
    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Bool
    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::String
    }
    @core.Expr::Ident(name~, span~) =>
      match env.get(name) {
        Some(ty) => ty
        None =>
          if has_alias_prefix(name, aliases) {
            @core.Type::Unit
          } else {
            match env.get_ctor(name) {
              Some(info) => {
                let inst = instantiate_ctor(env, info)
                inst.ret
              }
              None =>
                if @core.is_ctor_name(name) {
                  let map : Map[String, @core.Type] = {}
                  map[name] = @core.Type::Unit
                  @core.Type::Variant(map)
                } else {
                  raise TypeError::UnknownName(
                    name~,
                    span~,
                    suggestion=find_name_suggestion(env, aliases, name),
                  )
                }
            }
          }
      }
    @core.Expr::Call(name~, args~, span~) =>
      if has_alias_prefix(name, aliases) {
        @core.Type::Unit
      } else {
        type_call(env, name, args, aliases, effects, allow_effect, span)
      }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let tys : Array[@core.Type] = []
      for item in items {
        tys.push(type_expr_eff(env, item, aliases, effects, allow_effect))
      }
      @core.Type::Tuple(tys)
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let map : Map[String, @core.Type] = {}
      for field in fields {
        let ty = type_expr_eff(env, field.expr, aliases, effects, allow_effect)
        map[field.name] = ty
      }
      @core.Type::Record(map)
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      if items.is_empty() {
        @core.Type::Array(@core.Type::Unit)
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
            raise TypeError::Mismatch(
              expected=elem_ty,
              actual=item_ty,
              span=items[i].span(),
              context=Some("array item"),
            )
          }
        }
        @core.Type::Array(elem_ty)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      if fields.is_empty() {
        @core.Type::Map(@core.Type::Unit)
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
            raise TypeError::Mismatch(
              expected=val_ty,
              actual=item_ty,
              span=fields[i].span,
              context=Some("map value"),
            )
          }
        }
        @core.Type::Map(val_ty)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let cond_ty = type_expr_eff(env, cond, aliases, effects, allow_effect)
      if not(type_equal(env, cond_ty, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=cond_ty,
          span=cond.span(),
          context=Some("if condition"),
        )
      }
      let then_ty = type_block(env, then_body, aliases, effects, allow_effect)
      let else_ty = type_block(env, else_body, aliases, effects, allow_effect)
      if not(type_equal(env, then_ty, else_ty)) {
        raise TypeError::Mismatch(
          expected=then_ty,
          actual=else_ty,
          span~,
          context=Some("if branches"),
        )
      }
      then_ty
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      type_block(env, body, aliases, effects, allow_effect)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let try_scope = effect_scope_extend(effects, [
        @core.EffectAtom::Const("Error"),
      ])
      let try_ty = type_block(env, try_body, aliases, try_scope, allow_effect)
      let catch_ty = type_block(env, catch_body, aliases, effects, allow_effect)
      if not(type_equal(env, try_ty, catch_ty)) {
        raise TypeError::Mismatch(
          expected=try_ty,
          actual=catch_ty,
          span~,
          context=Some("try/catch branches"),
        )
      }
      try_ty
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      if arms.is_empty() {
        raise TypeError::BadMatch(message="empty match", span~)
      }
      let scrutinee_ty = normalize_type(
        env,
        type_expr_eff(env, scrutinee, aliases, effects, allow_effect),
      )
      let mut result : @core.Type? = None
      let mut has_wildcard = false
      let mut has_ctor = false
      let covered : Map[String, Bool] = {}
      for arm in arms {
        if is_top_wildcard(arm.pat) {
          has_wildcard = true
        }
        match arm.pat {
          @core.Pat::Ctor(name~, ..) => {
            has_ctor = true
            covered[name] = true
          }
          @core.Pat::Or(pats~, ..) =>
            for p in pats {
              match p {
                @core.Pat::Ctor(name~, ..) => {
                  has_ctor = true
                  covered[name] = true
                }
                _ => ()
              }
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
            if not(type_equal(env, g_ty, @core.Type::Bool)) {
              raise TypeError::Mismatch(
                expected=@core.Type::Bool,
                actual=g_ty,
                span=c.span(),
                context=Some("match guard"),
              )
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
              raise TypeError::Mismatch(
                expected=t,
                actual=arm_ty,
                span=arm.expr.span(),
                context=Some("match arm"),
              )
            }
          None => result = Some(arm_ty)
        }
      }
      if not(has_wildcard) {
        match scrutinee_ty {
          @core.Type::Variant(types) => {
            let mut missing = false
            for name, _ in types {
              if not(covered.contains(name)) {
                missing = true
                break
              }
            }
            if missing {
              raise TypeError::NonExhaustiveMatch(span~)
            }
          }
          _ => if not(has_ctor) { raise TypeError::NonExhaustiveMatch(span~) }
        }
      }
      match result {
        Some(t) => t
        None => @core.Type::Unit
      }
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      type_block(env, body, aliases, effects, true)
    }
    @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~) => {
      let mut uses_num = false
      for param in params {
        if has_num_type(param.ty) {
          uses_num = true
          break
        }
      }
      if not(uses_num) {
        match ret {
          Some(r) => uses_num = has_num_type(r)
          None => ()
        }
      }
      let num_var = if uses_num { Some(fresh_num_var(env)) } else { None }
      let scope_env = clone_env(env)
      let resolved_params : Array[@core.FuncParam] = []
      for param in params {
        let param_ty = match num_var {
          Some(n) => replace_num_type(param.ty, n)
          None => param.ty
        }
        let resolved = normalize_type(env, param_ty)
        let binding_ty = if param.label == @core.ParamLabel::Optional {
          @core.Type::Named(name="Option", args=[resolved])
        } else {
          resolved
        }
        scope_env.set(param.name, binding_ty)
        resolved_params.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: resolved,
        })
      }
      let normalized_effects = normalize_effects(fn_effects, span)
      let fn_scope = effect_scope_from_list(normalized_effects)
      let body_ty = type_block(scope_env, body, aliases, fn_scope, allow_effect)
      let resolved_effects = effect_set_to_atoms(
        effect_set_from_atoms(scope_env, normalized_effects),
      )
      let final_ret = match ret {
        Some(r) => {
          let ret_ty = match num_var {
            Some(n) => replace_num_type(r, n)
            None => r
          }
          let resolved = normalize_type(env, ret_ty)
          if not(type_equal(env, resolved, body_ty)) {
            raise TypeError::Mismatch(
              expected=resolved,
              actual=body_ty,
              span~,
              context=Some("fn return"),
            )
          }
          resolved
        }
        None => body_ty
      }
      @core.Type::Func(
        params=resolved_params,
        ret=final_ret,
        effects=resolved_effects,
      )
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      let cond_ty = type_expr_eff(env, cond, aliases, effects, allow_effect)
      if not(type_equal(env, cond_ty, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=cond_ty,
          span=cond.span(),
          context=Some("while condition"),
        )
      }
      let _ = type_block(env, body, aliases, effects, allow_effect)
      @core.Type::Unit
    }
    @core.Expr::Raise(value~, span~) => {
      let val_ty = type_expr_eff(env, value, aliases, effects, allow_effect)
      if not(type_equal(env, val_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=val_ty,
          span~,
          context=Some("raise"),
        )
      }
      require_effects(env, effects, [@core.EffectAtom::Const("Error")], span)
      @core.Type::Never
    }
  }
  record_expr_type(env, expr.span(), ty)
  ty
}

///|
fn is_top_wildcard(pat : @core.Pat) -> Bool {
  match pat {
    @core.Pat::Wildcard(..) => true
    @core.Pat::Bind(..) => true
    _ => false
  }
}

///|
fn collect_pattern_bindings(
  env : TypeEnv,
  pat : @core.Pat,
  scrutinee_ty : @core.Type,
) -> Map[String, @core.Type] raise TypeError {
  let out : Map[String, @core.Type] = {}
  let normalized = normalize_type(env, scrutinee_ty)
  collect_pattern_bindings_inner(env, out, pat, normalized)
  out
}

///|
fn generalize(env : TypeEnv, ty : @core.Type) -> TypeScheme raise TypeError {
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
  let num_vars : Array[Int] = []
  for id in vars {
    if env.num_vars.contains(id) {
      num_vars.push(id)
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
  TypeScheme::{ vars, num_vars, effect_vars, ty: normalized }
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
fn free_vars_in_type(env : TypeEnv, ty : @core.Type) -> Map[Int, Bool] {
  let out : Map[Int, Bool] = {}
  collect_free_vars(env, ty, out)
  out
}

///|
fn collect_free_vars(
  env : TypeEnv,
  ty : @core.Type,
  out : Map[Int, Bool],
) -> Unit {
  match resolve_type(env, ty) {
    @core.Type::Var(id) => out[id] = true
    @core.Type::Tuple(items) =>
      for item in items {
        collect_free_vars(env, item, out)
      }
    @core.Type::Record(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    @core.Type::Array(inner) => collect_free_vars(env, inner, out)
    @core.Type::Map(inner) => collect_free_vars(env, inner, out)
    @core.Type::ArrayBuilder(inner) => collect_free_vars(env, inner, out)
    @core.Type::MapBuilder(inner) => collect_free_vars(env, inner, out)
    @core.Type::Variant(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    @core.Type::Named(name=_, args~) =>
      for arg in args {
        collect_free_vars(env, arg, out)
      }
    @core.Type::Func(params~, ret~, effects=_) => {
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
fn free_effect_vars_in_type(
  env : TypeEnv,
  ty : @core.Type,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  collect_free_effect_vars(env, ty, out)
  out
}

///|
fn collect_free_effect_vars(
  env : TypeEnv,
  ty : @core.Type,
  out : Map[String, Bool],
) -> Unit {
  match resolve_type(env, ty) {
    @core.Type::Tuple(items) =>
      for item in items {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Record(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Array(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::Map(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::ArrayBuilder(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::MapBuilder(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::Variant(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Named(name=_, args~) =>
      for arg in args {
        collect_free_effect_vars(env, arg, out)
      }
    @core.Type::Func(params~, ret~, effects~) => {
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
  effects : Array[@core.EffectAtom],
  out : Map[String, Bool],
  visiting : Map[String, Bool],
) -> Unit {
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(_) => ()
      @core.EffectAtom::Var(name) =>
        collect_free_effect_var(env, name, out, visiting)
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
  out : Map[String, @core.Type],
  pat : @core.Pat,
  scrutinee_ty : @core.Type,
) -> Unit raise TypeError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span

    }
    @core.Pat::Bind(name~, span~) => {
      if out.contains(name) {
        raise TypeError::BadMatch(message="duplicate bind: " + name, span~)
      }
      out[name] = scrutinee_ty
    }
    @core.Pat::Ctor(name~, args~, span~) =>
      match scrutinee_ty {
        @core.Type::Variant(types) =>
          match types.get(name) {
            Some(field_ty) =>
              if args.length() == 0 {
                ()
              } else if args.length() == 1 {
                collect_pattern_bindings_inner(env, out, args[0], field_ty)
              } else {
                match field_ty {
                  @core.Type::Tuple(items) =>
                    if items.length() != args.length() {
                      raise TypeError::BadMatch(message="ctor arity", span~)
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
                  _ =>
                    raise TypeError::BadMatch(
                      message="ctor expects tuple",
                      span~,
                    )
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
                raise TypeError::BadMatch(
                  message="unknown ctor: " + name,
                  span~,
                )
              } else {
                for arg in args {
                  collect_pattern_bindings_loose(out, arg)
                }
              }
            }
          }
        @core.Type::Record(types) =>
          match types.get(name) {
            Some(field_ty) =>
              if args.length() == 0 {
                ()
              } else if args.length() == 1 {
                collect_pattern_bindings_inner(env, out, args[0], field_ty)
              } else {
                match field_ty {
                  @core.Type::Tuple(items) =>
                    if items.length() != args.length() {
                      raise TypeError::BadMatch(message="ctor arity", span~)
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
                  _ =>
                    raise TypeError::BadMatch(
                      message="ctor expects tuple",
                      span~,
                    )
                }
              }
            None =>
              for arg in args {
                collect_pattern_bindings_loose(out, arg)
              }
          }
        _ => raise TypeError::BadMatch(message="expected ctor variant", span~)
      }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Float)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Float,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Double)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Double,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::String(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Tuple(items~, span~) =>
      match scrutinee_ty {
        @core.Type::Tuple(types) => {
          if items.length() != types.length() {
            raise TypeError::BadMatch(message="tuple arity", span~)
          }
          for i in 0..<items.length() {
            collect_pattern_bindings_inner(env, out, items[i], types[i])
          }
        }
        _ => raise TypeError::BadMatch(message="expected tuple", span~)
      }
    @core.Pat::Record(fields~, span~) =>
      match scrutinee_ty {
        @core.Type::Record(types) =>
          for field in fields {
            match types.get(field.name) {
              Some(field_ty) =>
                collect_pattern_bindings_inner(env, out, field.pat, field_ty)
              None =>
                raise TypeError::BadMatch(
                  message="missing field: " + field.name,
                  span=field.span,
                )
            }
          }
        _ => raise TypeError::BadMatch(message="expected record", span~)
      }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        collect_pattern_bindings_inner(env, out, p, scrutinee_ty)
      }
    }
  }
}

///|
fn collect_pattern_bindings_loose(
  out : Map[String, @core.Type],
  pat : @core.Pat,
) -> Unit raise TypeError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span

    }
    @core.Pat::Bind(name~, span~) => {
      if out.contains(name) {
        raise TypeError::BadMatch(message="duplicate bind: " + name, span~)
      }
      out[name] = @core.Type::Unit
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_pattern_bindings_loose(out, arg)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pattern_bindings_loose(out, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pattern_bindings_loose(out, field.pat)
      }
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Pat::String(value~, span~) => {
      let _ = value
      let _ = span

    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        collect_pattern_bindings_loose(out, p)
      }
    }
  }
}

///|
fn type_block(
  env : TypeEnv,
  body : @core.Module,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let scope_env = clone_env(env)
  let mut last = @core.Type::Unit
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let scheme = type_let_expr(
          scope_env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        scope_env.set_scheme(name, scheme)
        last = scheme.ty
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        register_enum_def(scope_env, name, params, ctors, span)
        last = @core.Type::Unit
      }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        register_type_alias(scope_env, name, params, target, span)
        last = @core.Type::Unit
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        last = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
      }
      @core.Stmt::Flake(raw~, span~) => {
        let _ = raw
        let _ = span
        last = @core.Type::Unit
      }
      @core.Stmt::Alias(name~, target~, span~) => {
        match target {
          @core.AliasTarget::Module(_) => ()
          @core.AliasTarget::Name(target_name) =>
            match scope_env.get_scheme(target_name) {
              Some(scheme) => scope_env.set_scheme(name, scheme)
              None =>
                raise TypeError::UnknownName(
                  name=target_name,
                  span~,
                  suggestion=find_name_suggestion(
                    scope_env, aliases, target_name,
                  ),
                )
            }
        }
        last = @core.Type::Unit
      }
      @core.Stmt::Import(path~, span~) => {
        let _ = path
        let _ = span
        last = @core.Type::Unit
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_block(scope_env, body, aliases, effects, allow_effect)
        last = @core.Type::Unit
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        let scheme = TypeScheme::{ vars: [], num_vars: [], effect_vars: [], ty }
        scope_env.set_scheme(name, scheme)
        scope_env.set_purity(name, false)
        last = @core.Type::Unit
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(scope_env, pat, ty)
        for name, bound_ty in bindings {
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            ty: bound_ty,
          }
          scope_env.set_scheme(name, scheme)
          scope_env.set_purity(name, true)
        }
        last = ty
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        match scope_env.get_scheme(name) {
          Some(scheme) => {
            let expected = instantiate_scheme(scope_env, scheme)
            if not(type_equal(scope_env, expected, ty)) {
              raise TypeError::Mismatch(
                expected~,
                actual=ty,
                span~,
                context=Some("assignment"),
              )
            }
          }
          None =>
            raise TypeError::UnknownName(
              name~,
              span~,
              suggestion=find_name_suggestion(scope_env, aliases, name),
            )
        }
        last = @core.Type::Unit
      }
    }
  }
  last
}

///|
fn ensure_num_operand(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Int | @core.Type::Float | @core.Type::Double => ()
    @core.Type::Var(id) => mark_num_var(env, id)
    _ =>
      raise TypeError::Mismatch(
        expected=@core.Type::Int,
        actual=resolved,
        span~,
        context=Some("argument"),
      )
  }
}

///|
fn type_call(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type raise TypeError {
  match env.get(name) {
    Some(ty) =>
      match ty {
        @core.Type::Func(params~, ret~, effects=fn_effects) => {
          check_call_args(
            env, params, args, aliases, effects, allow_effect, call_span,
          )
          require_effects(env, effects, fn_effects, call_span)
          ret
        }
        _ => raise TypeError::BadCall(message=name, span=call_span)
      }
    None =>
      match env.get_ctor(name) {
        Some(info) => {
          let pos_args = extract_positional_args(args, name, call_span)
          let inst = instantiate_ctor(env, info)
          match inst.payload {
            @core.Type::Unit =>
              if pos_args.length() != 0 {
                raise TypeError::BadCall(message=name, span=call_span)
              }
            @core.Type::Tuple(items) =>
              if pos_args.length() != items.length() {
                raise TypeError::BadCall(message=name, span=call_span)
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
                    raise TypeError::Mismatch(
                      expected=items[i],
                      actual=arg_ty,
                      span=pos_args[i].span(),
                      context=Some("ctor argument"),
                    )
                  }
                }
              }
            _ =>
              if pos_args.length() != 1 {
                raise TypeError::BadCall(message=name, span=call_span)
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
                    span=pos_args[0].span(),
                    context=Some("ctor argument"),
                  )
                }
              }
          }
          inst.ret
        }
        None =>
          if @core.is_ctor_name(name) {
            let pos_args = extract_positional_args(args, name, call_span)
            let field_ty = if pos_args.length() == 0 {
              @core.Type::Unit
            } else if pos_args.length() == 1 {
              type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
            } else {
              let tys : Array[@core.Type] = []
              for arg in pos_args {
                tys.push(
                  type_expr_eff(env, arg, aliases, effects, allow_effect),
                )
              }
              @core.Type::Tuple(tys)
            }
            let map : Map[String, @core.Type] = {}
            map[name] = field_ty
            @core.Type::Variant(map)
          } else {
            match name {
              "path" => {
                let pos_args = extract_positional_args(args, "path", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="path", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Path
              }
              "addr" => {
                let pos_args = extract_positional_args(args, "addr", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="addr", span=call_span)
                }
                match pos_args[0] {
                  @core.Expr::String(value=s, span~) =>
                    match env.get_addr_type(s) {
                      Some(ty) => ty
                      None =>
                        raise TypeError::UnknownName(
                          name="addr:" + s,
                          span~,
                          suggestion=None,
                        )
                    }
                  _ => raise TypeError::BadCall(message="addr", span=call_span)
                }
              }
              "sh" => {
                let pos_args = extract_positional_args(args, "sh", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="sh", span=call_span)
                }
                require_effects(env, effects, builtin_effects("sh"), call_span)
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(name="sh", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "array_builder" => {
                let pos_args = extract_positional_args(
                  args, "array_builder", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="array_builder",
                    span=call_span,
                  )
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(
                    name="array_builder",
                    span=call_span,
                  )
                }
                let elem = fresh_type_var(env)
                @core.Type::ArrayBuilder(elem)
              }
              "array_builder_push" => {
                let pos_args = extract_positional_args(
                  args, "array_builder_push", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="array_builder_push",
                    span=call_span,
                  )
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(
                    name="array_builder_push",
                    span=call_span,
                  )
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
                if not(
                    type_equal(
                      env,
                      builder_ty,
                      @core.Type::ArrayBuilder(elem_ty),
                    ),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::ArrayBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, value_ty, elem_ty)) {
                  raise TypeError::Mismatch(
                    expected=elem_ty,
                    actual=value_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "array_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "array_builder_freeze", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="array_builder_freeze",
                    span=call_span,
                  )
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(
                    name="array_builder_freeze",
                    span=call_span,
                  )
                }
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(
                      env,
                      builder_ty,
                      @core.Type::ArrayBuilder(elem_ty),
                    ),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::ArrayBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(elem_ty)
              }
              "map_builder" => {
                let pos_args = extract_positional_args(
                  args, "map_builder", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="map_builder",
                    span=call_span,
                  )
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(
                    name="map_builder",
                    span=call_span,
                  )
                }
                let value = fresh_type_var(env)
                @core.Type::MapBuilder(value)
              }
              "map_builder_set" => {
                let pos_args = extract_positional_args(
                  args, "map_builder_set", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(
                    message="map_builder_set",
                    span=call_span,
                  )
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(
                    name="map_builder_set",
                    span=call_span,
                  )
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
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(env, builder_ty, @core.Type::MapBuilder(elem_ty)),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::MapBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, value_ty, elem_ty)) {
                  raise TypeError::Mismatch(
                    expected=elem_ty,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "map_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "map_builder_freeze", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="map_builder_freeze",
                    span=call_span,
                  )
                }
                if not(allow_effect) {
                  raise TypeError::EffectNotAllowed(
                    name="map_builder_freeze",
                    span=call_span,
                  )
                }
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(env, builder_ty, @core.Type::MapBuilder(elem_ty)),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::MapBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Map(elem_ty)
              }
              "array_length" => {
                let pos_args = extract_positional_args(
                  args, "array_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="array_length",
                    span=call_span,
                  )
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, array_ty, @core.Type::Array(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Array(elem_ty),
                    actual=array_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "array_get" => {
                let pos_args = extract_positional_args(
                  args, "array_get", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="array_get", span=call_span)
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
                if not(type_equal(env, index_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=index_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, array_ty, @core.Type::Array(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Array(elem_ty),
                    actual=array_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                elem_ty
              }
              "map_get" => {
                let pos_args = extract_positional_args(
                  args, "map_get", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="map_get", span=call_span)
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
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, map_ty, @core.Type::Map(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Map(elem_ty),
                    actual=map_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                elem_ty
              }
              "string_length" => {
                let pos_args = extract_positional_args(
                  args, "string_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_length",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_char_code_at" => {
                let pos_args = extract_positional_args(
                  args, "string_char_code_at", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_char_code_at",
                    span=call_span,
                  )
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
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, index_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=index_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_substring" => {
                let pos_args = extract_positional_args(
                  args, "string_substring", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(
                    message="string_substring",
                    span=call_span,
                  )
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
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, start_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=start_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, end_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=end_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_concat" => {
                let pos_args = extract_positional_args(
                  args, "string_concat", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_concat",
                    span=call_span,
                  )
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
                if not(type_equal(env, left_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=left_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, right_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=right_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_equals" => {
                let pos_args = extract_positional_args(
                  args, "string_equals", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_equals",
                    span=call_span,
                  )
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
                if not(type_equal(env, left_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=left_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, right_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=right_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "string_split" => {
                let pos_args = extract_positional_args(
                  args, "string_split", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_split",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let sep_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, sep_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=sep_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(@core.Type::String)
              }
              "string_index_of" => {
                let pos_args = extract_positional_args(
                  args, "string_index_of", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_index_of",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let sub_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, sub_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=sub_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_contains" => {
                let pos_args = extract_positional_args(
                  args, "string_contains", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_contains",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let sub_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, sub_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=sub_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "string_trim" => {
                let pos_args = extract_positional_args(
                  args, "string_trim", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_trim",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "__add" => {
                let pos_args = extract_positional_args(args, "__add", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__add", span=call_span)
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
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__sub" => {
                let pos_args = extract_positional_args(args, "__sub", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__sub", span=call_span)
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
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__mul" => {
                let pos_args = extract_positional_args(args, "__mul", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__mul", span=call_span)
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
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__div" | "__mod" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
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
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__index" => {
                let pos_args = extract_positional_args(
                  args, "__index", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__index", span=call_span)
                }
                let container_ty = type_expr_eff(
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
                let elem_ty = fresh_type_var(env)
                match container_ty {
                  @core.Type::Array(_) => {
                    if not(type_equal(env, index_ty, @core.Type::Int)) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::Int,
                        actual=index_ty,
                        span=pos_args[1].span(),
                        context=Some("index"),
                      )
                    }
                    if not(
                        type_equal(
                          env,
                          container_ty,
                          @core.Type::Array(elem_ty),
                        ),
                      ) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::Array(elem_ty),
                        actual=container_ty,
                        span=pos_args[0].span(),
                        context=Some("argument"),
                      )
                    }
                    elem_ty
                  }
                  @core.Type::Map(_) => {
                    if not(type_equal(env, index_ty, @core.Type::String)) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::String,
                        actual=index_ty,
                        span=pos_args[1].span(),
                        context=Some("index"),
                      )
                    }
                    if not(
                        type_equal(env, container_ty, @core.Type::Map(elem_ty)),
                      ) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::Map(elem_ty),
                        actual=container_ty,
                        span=pos_args[0].span(),
                        context=Some("argument"),
                      )
                    }
                    elem_ty
                  }
                  _ => {
                    let _ = index_ty
                    let _ = elem_ty
                    raise TypeError::BadCall(
                      message="__index: not indexable",
                      span=call_span,
                    )
                  }
                }
              }
              "__eq" => {
                let pos_args = extract_positional_args(args, "__eq", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__eq", span=call_span)
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
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "__lt" => {
                let pos_args = extract_positional_args(args, "__lt", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__lt", span=call_span)
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
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "__neg" => {
                let pos_args = extract_positional_args(args, "__neg", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="__neg", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_num_operand(env, a, pos_args[0].span())
                a
              }
              "__assert" => {
                let pos_args = extract_positional_args(
                  args, "__assert", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="__assert", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, @core.Type::Bool)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Bool,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "record_set" => {
                let pos_args = extract_positional_args(
                  args, "record_set", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message="record_set", span=call_span)
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
                if not(type_equal(env, field_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=field_ty,
                    span=pos_args[1].span(),
                    context=Some("record field name"),
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
                  @core.Type::Record(fields) =>
                    match pos_args[1] {
                      @core.Expr::String(value=name, span~) =>
                        match fields.get(name) {
                          Some(expect) =>
                            if not(type_equal(env, expect, value_ty)) {
                              raise TypeError::Mismatch(
                                expected=expect,
                                actual=value_ty,
                                span=pos_args[2].span(),
                                context=Some("record field value"),
                              )
                            }
                          None =>
                            raise TypeError::BadCall(
                              message="record_set",
                              span~,
                            )
                        }
                      _ => ()
                    }
                  _ =>
                    raise TypeError::BadCall(
                      message="record_set",
                      span=call_span,
                    )
                }
                record_ty
              }
              "map_keys" => {
                let pos_args = extract_positional_args(
                  args, "map_keys", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="map_keys", span=call_span)
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, map_ty)
                match resolved {
                  @core.Type::Map(_) => @core.Type::Array(@core.Type::String)
                  _ =>
                    raise TypeError::BadCall(message="map_keys", span=call_span)
                }
              }
              "map_values" => {
                let pos_args = extract_positional_args(
                  args, "map_values", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="map_values", span=call_span)
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, map_ty)
                match resolved {
                  @core.Type::Map(elem_ty) => @core.Type::Array(elem_ty)
                  _ =>
                    raise TypeError::BadCall(
                      message="map_values",
                      span=call_span,
                    )
                }
              }
              "map_has_key" => {
                let pos_args = extract_positional_args(
                  args, "map_has_key", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="map_has_key",
                    span=call_span,
                  )
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, map_ty)
                match resolved {
                  @core.Type::Map(_) => ()
                  _ =>
                    raise TypeError::BadCall(
                      message="map_has_key",
                      span=call_span,
                    )
                }
                let key_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "array_slice" => {
                let pos_args = extract_positional_args(
                  args, "array_slice", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(
                    message="array_slice",
                    span=call_span,
                  )
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, array_ty)
                let elem_ty = match resolved {
                  @core.Type::Array(elem_ty) => elem_ty
                  _ =>
                    raise TypeError::BadCall(
                      message="array_slice",
                      span=call_span,
                    )
                }
                let start_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, start_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=start_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let end_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, end_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=end_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(elem_ty)
              }
              "int_to_float" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "int_to_float",
                  @core.Type::Int,
                  @core.Type::Float,
                )
              "int_to_double" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "int_to_double",
                  @core.Type::Int,
                  @core.Type::Double,
                )
              "float_to_int" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "float_to_int",
                  @core.Type::Float,
                  @core.Type::Int,
                )
              "float_to_double" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "float_to_double",
                  @core.Type::Float,
                  @core.Type::Double,
                )
              "double_to_int" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "double_to_int",
                  @core.Type::Double,
                  @core.Type::Int,
                )
              "double_to_float" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "double_to_float",
                  @core.Type::Double,
                  @core.Type::Float,
                )
              "__to_string" => {
                let pos_args = extract_positional_args(
                  args, "__to_string", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="__to_string",
                    span=call_span,
                  )
                }
                let _ = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                @core.Type::String
              }
              _ => raise TypeError::BadCall(message=name, span=call_span)
            }
          }
      }
  }
}

///|
fn type_check_unary_convert(
  env : TypeEnv,
  args : Array[@core.CallArg],
  call_span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  name : String,
  from_ty : @core.Type,
  to_ty : @core.Type,
) -> @core.Type raise TypeError {
  let pos_args = extract_positional_args(args, name, call_span)
  if pos_args.length() != 1 {
    raise TypeError::BadCall(message=name, span=call_span)
  }
  let arg_ty = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
  if not(type_equal(env, arg_ty, from_ty)) {
    raise TypeError::Mismatch(
      expected=from_ty,
      actual=arg_ty,
      span=pos_args[0].span(),
      context=Some("argument"),
    )
  }
  to_ty
}

///|
fn is_non_expansive_expr(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
) -> Bool {
  match expr {
    @core.Expr::Int(..) => true
    @core.Expr::Float(..) => true
    @core.Expr::Double(..) => true
    @core.Expr::Bool(..) => true
    @core.Expr::String(..) => true
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      not(has_alias_prefix(name, aliases))
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let mut ok = true
      for item in items {
        if not(is_non_expansive_expr(env, item, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(is_non_expansive_expr(env, field.expr, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      let mut ok = true
      for item in items {
        if not(is_non_expansive_expr(env, item, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(is_non_expansive_expr(env, field.expr, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Fn(..) => true
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      if has_alias_prefix(name, aliases) {
        false
      } else if @core.is_ctor_name(name) {
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
    }
    _ => false
  }
}

///|
fn type_let_expr(
  env : TypeEnv,
  rec : Bool,
  name : String,
  expr : @core.Expr,
  span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> TypeScheme raise TypeError {
  if rec {
    match expr {
      @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span=fn_span) =>
        match ret {
          None => raise TypeError::BadRec(message="missing return type", span~)
          Some(r) => {
            let mut uses_num = false
            for param in params {
              if has_num_type(param.ty) {
                uses_num = true
                break
              }
            }
            if not(uses_num) {
              uses_num = has_num_type(r)
            }
            let num_var = if uses_num { Some(fresh_num_var(env)) } else { None }
            let replaced_params : Array[@core.FuncParam] = []
            for param in params {
              let param_ty = match num_var {
                Some(n) => replace_num_type(param.ty, n)
                None => param.ty
              }
              replaced_params.push(@core.FuncParam::{
                name: param.name,
                label: param.label,
                ty: param_ty,
              })
            }
            let replaced_ret = match num_var {
              Some(n) => replace_num_type(r, n)
              None => r
            }
            let normalized_effects = normalize_effects(fn_effects, fn_span)
            let fn_ty = normalize_type(
              env,
              @core.Type::Func(
                params=replaced_params,
                ret=replaced_ret,
                effects=normalized_effects,
              ),
            )
            env.set(name, fn_ty)
            let ty = type_expr_eff(
              env,
              @core.Expr::Fn(
                params=replaced_params,
                ret=Some(replaced_ret),
                effects=normalized_effects,
                body~,
                span=fn_span,
              ),
              aliases,
              effects,
              allow_effect,
            )
            if not(type_equal(env, ty, fn_ty)) {
              raise TypeError::Mismatch(
                expected=fn_ty,
                actual=ty,
                span=fn_span,
                context=Some("recursive binding"),
              )
            }
            TypeScheme::{ vars: [], num_vars: [], effect_vars: [], ty: fn_ty }
          }
        }
      _ => raise TypeError::BadRec(message="expected fn", span~)
    }
  } else {
    let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
    if allow_effect {
      if is_non_expansive_expr(env, expr, aliases) {
        generalize(env, ty)
      } else {
        let resolved = resolve_type(env, ty)
        let normalized = normalize_type(env, resolved)
        TypeScheme::{ vars: [], num_vars: [], effect_vars: [], ty: normalized }
      }
    } else {
      generalize(env, ty)
    }
  }
}

///|
priv struct ArgType {
  label : String?
  ty : @core.Type
  span : @core.Span
}

///|
fn extract_positional_args(
  args : Array[@core.CallArg],
  name : String,
  call_span : @core.Span,
) -> Array[@core.Expr] raise TypeError {
  let _ = call_span
  let out : Array[@core.Expr] = []
  for arg in args {
    match arg.label {
      Some(_) => raise TypeError::BadCall(message=name, span=arg.span)
      None => out.push(arg.expr)
    }
  }
  out
}

///|
fn check_call_args(
  env : TypeEnv,
  params : Array[@core.FuncParam],
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> Unit raise TypeError {
  let arg_types : Array[ArgType] = []
  for arg in args {
    let ty = type_expr_eff(env, arg.expr, aliases, effects, allow_effect)
    arg_types.push(ArgType::{ label: arg.label, ty, span: arg.span })
  }
  let positional : Array[@core.FuncParam] = []
  for param in params {
    if param.label == @core.ParamLabel::Positional {
      positional.push(param)
    }
  }
  let mut pos_index = 0
  let used_labels : Map[String, Bool] = {}
  for arg in arg_types {
    match arg.label {
      None => {
        if pos_index >= positional.length() {
          raise TypeError::BadCall(
            message="too many positional args",
            span=arg.span,
          )
        }
        let param = positional[pos_index]
        pos_index += 1
        if not(type_equal(env, param.ty, arg.ty)) {
          raise TypeError::Mismatch(
            expected=param.ty,
            actual=arg.ty,
            span=arg.span,
            context=Some("argument"),
          )
        }
      }
      Some(label) => {
        if used_labels.contains(label) {
          raise TypeError::BadCall(
            message="duplicate label: " + label,
            span=arg.span,
          )
        }
        let mut found : @core.FuncParam? = None
        for param in params {
          if param.label != @core.ParamLabel::Positional && param.name == label {
            found = Some(param)
            break
          }
        }
        match found {
          Some(param) => {
            used_labels[label] = true
            if not(type_equal(env, param.ty, arg.ty)) {
              raise TypeError::Mismatch(
                expected=param.ty,
                actual=arg.ty,
                span=arg.span,
                context=Some("argument"),
              )
            }
          }
          None =>
            raise TypeError::BadCall(
              message="unknown label: " + label,
              span=arg.span,
            )
        }
      }
    }
  }
  if pos_index != positional.length() {
    raise TypeError::BadCall(message="missing positional args", span=call_span)
  }
  for param in params {
    if param.label == @core.ParamLabel::Required &&
      not(used_labels.contains(param.name)) {
      raise TypeError::BadCall(
        message="missing label: " + param.name,
        span=call_span,
      )
    }
  }
}

///|
fn normalize_type(env : TypeEnv, ty : @core.Type) -> @core.Type raise TypeError {
  let resolved = resolve_type(env, ty)
  let visiting : Map[String, Bool] = {}
  normalize_type_inner(env, resolved, visiting)
}

///|
fn normalize_type_inner(
  env : TypeEnv,
  ty : @core.Type,
  visiting : Map[String, Bool],
) -> @core.Type raise TypeError {
  match ty {
    @core.Type::Named(name~, args~) => {
      let normalized_args : Array[@core.Type] = []
      for arg in args {
        normalized_args.push(normalize_type_inner(env, arg, visiting))
      }
      if visiting.contains(name) {
        match env.get_enum_def(name) {
          Some(_) => @core.Type::Named(name~, args=normalized_args)
          None =>
            raise TypeError::BadTypeDef(
              message="recursive type: " + name,
              span=unknown_span(),
            )
        }
      } else {
        visiting[name] = true
        let normalized = match env.get_type_alias(name) {
          Some(type_alias) => {
            if type_alias.params.length() != normalized_args.length() {
              raise TypeError::BadTypeDef(
                message="type arity: " + name,
                span=unknown_span(),
              )
            }
            let mapping : Map[String, @core.Type] = {}
            for i in 0..<type_alias.params.length() {
              mapping[type_alias.params[i]] = normalized_args[i]
            }
            let substituted = substitute_type(type_alias.target, mapping)
            normalize_type_inner(env, substituted, visiting)
          }
          None =>
            match env.get_enum_def(name) {
              Some(def) => {
                if def.params.length() != normalized_args.length() {
                  raise TypeError::BadTypeDef(
                    message="type arity: " + name,
                    span=unknown_span(),
                  )
                }
                let mapping : Map[String, @core.Type] = {}
                for i in 0..<def.params.length() {
                  mapping[def.params[i]] = normalized_args[i]
                }
                let ctor_map : Map[String, @core.Type] = {}
                for ctor in def.ctors {
                  let base_payload = if ctor.args.length() == 0 {
                    @core.Type::Unit
                  } else if ctor.args.length() == 1 {
                    ctor.args[0]
                  } else {
                    @core.Type::Tuple(ctor.args)
                  }
                  let substituted = substitute_type(base_payload, mapping)
                  ctor_map[ctor.name] = normalize_type_inner(
                    env, substituted, visiting,
                  )
                }
                @core.Type::Variant(ctor_map)
              }
              None =>
                raise TypeError::UnknownType(
                  name~,
                  span=unknown_span(),
                  suggestion=find_type_suggestion(env, name),
                )
            }
        }
        visiting.remove(name)
        normalized
      }
    }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(normalize_type_inner(env, item, visiting))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = normalize_type_inner(env, item, visiting)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(normalize_type_inner(env, inner, visiting))
    @core.Type::Map(inner) =>
      @core.Type::Map(normalize_type_inner(env, inner, visiting))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(normalize_type_inner(env, inner, visiting))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(normalize_type_inner(env, inner, visiting))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = normalize_type_inner(env, item, visiting)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Param(_) => ty
    @core.Type::Var(_) => ty
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: normalize_type_inner(env, param.ty, visiting),
        })
      }
      @core.Type::Func(
        params=out,
        ret=normalize_type_inner(env, ret, visiting),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn type_equal(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
) -> Bool raise TypeError {
  unify_types(env, a, b)
}

///|
/// Completion helper: true if param type can accept receiver type.
pub fn completion_param_matches(
  env : TypeEnv,
  receiver : @core.Type,
  param : @core.Type,
) -> Bool {
  let recv = normalize_type(env, receiver) catch { _ => receiver }
  let param_ty = normalize_type(env, param) catch { _ => param }
  match param_ty {
    @core.Type::Var(_) | @core.Type::Param(_) => true
    _ =>
      match recv {
        @core.Type::Var(_) | @core.Type::Param(_) => true
        _ => type_equal(env, recv, param_ty) catch { _ => false }
      }
  }
}

///|
fn unify_types(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
) -> Bool raise TypeError {
  let left = resolve_type(env, a)
  let right = resolve_type(env, b)
  match (left, right) {
    (@core.Type::Never, _) => true
    (_, @core.Type::Never) => true
    (@core.Type::Named(name=an, args=aa), @core.Type::Named(name=bn, args=bb)) =>
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
    (@core.Type::Var(id), t) => bind_var(env, id, t)
    (t, @core.Type::Var(id)) => bind_var(env, id, t)
    (@core.Type::Param(a0), @core.Type::Param(b0)) => a0 == b0
    (@core.Type::Param(_), _) => false
    (_, @core.Type::Param(_)) => false
    (@core.Type::Named(..), _) => {
      let nl = normalize_type(env, left)
      unify_types(env, nl, right)
    }
    (_, @core.Type::Named(..)) => {
      let nr = normalize_type(env, right)
      unify_types(env, left, nr)
    }
    (@core.Type::Int, @core.Type::Int) => true
    (@core.Type::Float, @core.Type::Float) => true
    (@core.Type::Double, @core.Type::Double) => true
    (@core.Type::Bool, @core.Type::Bool) => true
    (@core.Type::String, @core.Type::String) => true
    (@core.Type::Path, @core.Type::Path) => true
    (@core.Type::Unit, @core.Type::Unit) => true
    (@core.Type::Tuple(xs), @core.Type::Tuple(ys)) =>
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
    (@core.Type::Record(ax), @core.Type::Record(bx)) =>
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
    (@core.Type::Array(ae), @core.Type::Array(be)) => unify_types(env, ae, be)
    (@core.Type::Map(av), @core.Type::Map(bv)) => unify_types(env, av, bv)
    (@core.Type::ArrayBuilder(ae), @core.Type::ArrayBuilder(be)) =>
      unify_types(env, ae, be)
    (@core.Type::MapBuilder(av), @core.Type::MapBuilder(bv)) =>
      unify_types(env, av, bv)
    (@core.Type::Variant(ax), @core.Type::Variant(bx)) =>
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
      @core.Type::Func(params=pa, ret=ra, effects=ea),
      @core.Type::Func(params=pb, ret=rb, effects=eb),
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
  a : @core.FuncParam,
  b : @core.FuncParam,
) -> Bool raise TypeError {
  if a.label != b.label {
    return false
  }
  if a.label != @core.ParamLabel::Positional && a.name != b.name {
    return false
  }
  unify_types(env, a.ty, b.ty)
}

///|
fn bind_var(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  let resolved = resolve_type(env, ty)
  if is_num_var(env, id) {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          mark_num_var(env, other)
          env.subs[id] = resolved
          true
        }
      @core.Type::Int | @core.Type::Float | @core.Type::Double => {
        env.subs[id] = resolved
        true
      }
      _ => false
    }
  } else {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          env.subs[id] = resolved
          true
        }
      _ =>
        if occurs_in(env, id, resolved) {
          false
        } else {
          env.subs[id] = resolved
          true
        }
    }
  }
}

///|
fn occurs_in(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  match resolve_type(env, ty) {
    @core.Type::Var(other) => other == id
    @core.Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Array(inner) => occurs_in(env, id, inner)
    @core.Type::Map(inner) => occurs_in(env, id, inner)
    @core.Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Named(name=_, args~) => {
      let mut found = false
      for arg in args {
        if occurs_in(env, id, arg) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Func(params~, ret~, effects=_) => {
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
fn has_alias_prefix(name : String, aliases : Map[String, @core.Ref]) -> Bool {
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
