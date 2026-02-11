///|
/// @core.Type checking for xsh
suberror TypeError {
  UnknownName(name~ : String, span~ : @core.Span, suggestion~ : String?)
  UnknownType(name~ : String, span~ : @core.Span, suggestion~ : String?)
  DuplicateDecl(name~ : String, span~ : @core.Span)
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
  EffectGuardNotSatisfied(
    operation~ : String,
    missing_effect~ : String?,
    missing_do_boundary~ : Bool,
    span~ : @core.Span
  )
} derive(Show, Eq)

///|
// Global counter to avoid type var id collisions across env forks.
let global_next_type_var : Ref[Int] = @ref.new(0)

///|
let cached_prelude_env : Ref[TypeEnv?] = @ref.new(None)

///|
fn suggestion_hint(suggestion : String?) -> String? {
  match suggestion {
    Some(name) => Some("did you mean `" + name + "`?")
    None => None
  }
}

///|
fn is_do_boundary_operation(name : String) -> Bool {
  match name {
    "sh"
    | "sh_lines"
    | "sleep"
    | "stdout_write_char"
    | "stdin_read_char"
    | "stdout_write_stream"
    | "stdin_read_stream"
    | "array_builder"
    | "array_builder_push"
    | "array_builder_freeze"
    | "map_builder"
    | "map_builder_set"
    | "map_builder_freeze" => true
    _ => false
  }
}

///|
fn effect_not_allowed_hint(name : String) -> String? {
  if is_do_boundary_operation(name) {
    Some("wrap in `do { ... }` to allow side effects")
  } else if name == "Error" {
    Some("declare `with {Error}` or handle with `try { ... } catch { ... }`")
  } else if name == "effect" {
    Some("declare a compatible `with { ... }` effect set on this function")
  } else {
    Some(
      "declare `with {" +
      name +
      "}` (or a compatible effect row) on this function",
    )
  }
}

///|
fn effect_guard_hint(
  operation : String,
  missing_effect : String?,
  missing_do_boundary : Bool,
) -> String? {
  match missing_effect {
    Some(effect_name) =>
      if missing_do_boundary {
        Some(
          "declare `with {" +
          effect_name +
          "}` (or a compatible effect row) and wrap in `do { ... }`",
        )
      } else {
        effect_not_allowed_hint(effect_name)
      }
    None =>
      if missing_do_boundary {
        effect_not_allowed_hint(operation)
      } else {
        None
      }
  }
}

///|
fn effect_guard_note(
  operation : String,
  missing_effect : String?,
  missing_do_boundary : Bool,
) -> String? {
  let mut note = ""
  match missing_effect {
    Some(effect_name) =>
      note = "missing effect declaration: `" + effect_name + "`"
    None => ()
  }
  if missing_do_boundary {
    let do_note = "missing effect boundary: wrap `" +
      operation +
      "(...)` in `do { ... }`"
    if note == "" {
      note = do_note
    } else {
      note = note + "\n" + do_note
    }
  }
  if note == "" {
    None
  } else {
    Some(note)
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
    TypeError::DuplicateDecl(name~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "duplicate declaration: " + name,
        span: Some(span),
        hint: None,
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
    TypeError::EffectGuardNotSatisfied(
      operation~,
      missing_effect~,
      missing_do_boundary~,
      span~
    ) =>
      @core.Diagnostic::{
        stage: "type",
        message: "effect requirements not satisfied: `" + operation + "`",
        span: Some(span),
        hint: effect_guard_hint(operation, missing_effect, missing_do_boundary),
        note: effect_guard_note(operation, missing_effect, missing_do_boundary),
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
    _ => {
      // "duplicate bind: " has length 16
      let prefix = "duplicate bind: "
      if message.has_prefix(prefix) {
        let chars = message.to_array()
        let name = chars[prefix.length():]
          .iter()
          .fold(init=StringBuilder::new(), fn(sb, c) {
            sb.write_char(c)
            sb
          })
          .to_string()
        "duplicate binding: `" + name + "`"
      } else {
        message
      }
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
  expr_types : Map[String, @core.Type]
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
  let env = get_cached_prelude_env_for_module()
  let exported_names = collect_exported_names(ast.stmts)
  type_check_stmts(
    env,
    ast.stmts,
    aliases,
    effect_scope_all(),
    false,
    exported_names,
  ) catch {
    e => raise e.resolve_vars(env)
  }
}

///|
pub fn get_cached_prelude_env_for_module() -> TypeEnv raise TypeError {
  match cached_prelude_env.val {
    Some(seed) => seed.clone_for_module()
    None => {
      let seed = TypeEnv::new()
      ensure_prelude_option(seed)
      ensure_prelude_functions(seed, {})
      cached_prelude_env.val = Some(seed)
      seed.clone_for_module()
    }
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
  let exported_names = collect_exported_names(ast.stmts)
  type_check_stmts(
    env,
    ast.stmts,
    aliases,
    effect_scope_all(),
    false,
    exported_names,
  ) catch {
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
  exported_names : Map[String, Bool],
) -> TypeEnv raise TypeError {
  let declared_in_scope : Map[String, Bool] = {}
  let ensure_fresh_value_binding = fn(
    name : String,
    span : @core.Span,
  ) -> Unit raise TypeError {
    if name == "_" {
      return
    }
    if declared_in_scope.contains(name) {
      raise TypeError::DuplicateDecl(name~, span~)
    }
  }
  let record_value_binding = fn(name : String) {
    if name == "_" {
      return
    }
    declared_in_scope[name] = true
  }
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let scheme = type_let_expr(
          env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        if name != "_" {
          if exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          let info = purity_for_let(env, rec, name, expr)
          env.set_purity(name, info.value)
          record_value_binding(name)
        }
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        register_enum_def(env, name, params, ctors, span)
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        register_type_alias(env, name, params, target, span)
      @core.Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, span~) =>
        register_trait_def(env, name, supertraits, open_impl, exported, span)
      @core.Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target~,
        span~
      ) =>
        register_trait_impl(
          env, type_params, type_bounds, trait_name, target, span,
        )
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        let _ = type_expr_eff(env, expr, aliases, effects, allow_effect)
      }
      @core.Stmt::Import(..) => ()
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let scheme = type_let_expr(
          env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        if name != "_" {
          env.set_exported_scheme(name, scheme)
          let info = purity_for_let(env, rec, name, expr)
          env.set_purity(name, info.value)
          record_value_binding(name)
        }
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        register_enum_def(env, name, params, ctors, span)
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        register_type_alias(env, name, params, target, span)
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) => ()
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_check_stmts(
          clone_env(env),
          body.stmts,
          aliases,
          effects,
          allow_effect,
          {},
        )
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_check_stmts(
          clone_env(env),
          body.stmts,
          aliases,
          effects,
          allow_effect,
          {},
        )
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        if name != "_" {
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty,
          }
          if exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          env.set_purity(name, false)
          record_value_binding(name)
        }
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(env, pat, ty)
        for name, bound_ty in bindings {
          ensure_fresh_value_binding(name, span)
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty: bound_ty,
          }
          if exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          env.set_purity(name, true)
          record_value_binding(name)
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
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        // Type check target[index] = value as __set_index(target, index, value)
        let _ = type_expr_eff(env, target, aliases, effects, allow_effect)
        let _ = type_expr_eff(env, index, aliases, effects, allow_effect)
        let _ = type_expr_eff(env, value, aliases, effects, allow_effect)
        let _ = span
        // For now, just check that all sub-expressions type check
        // More precise checking would verify target is array/map compatible
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~) =>
        register_struct_def(env, name, params, fields, span)
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        register_struct_def(env, name, params, fields, span)
    }
  }
  env
}

///|
fn collect_exported_names(stmts : Array[@core.Stmt]) -> Map[String, Bool] {
  let exports : Map[String, Bool] = {}
  let defined : Map[String, Bool] = {}
  let mut has_late_exports = false
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, ..) => {
        let _ = rec
        defined[name] = true
      }
      @core.Stmt::LetMut(name~, ..) => defined[name] = true
      @core.Stmt::EnumDef(name~, ..) => defined[name] = true
      @core.Stmt::TypeAlias(name~, ..) => defined[name] = true
      @core.Stmt::TraitDef(name~, ..) => defined[name] = true
      @core.Stmt::StructDef(name~, ..) => defined[name] = true
      @core.Stmt::ExportLet(rec~, name~, ..) => {
        let _ = rec
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::ExportEnumDef(name~, ctors~, ..) => {
        defined[name] = true
        exports[name] = true
        for ctor in ctors {
          defined[ctor.name] = true
          exports[ctor.name] = true
        }
      }
      @core.Stmt::ExportTypeAlias(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::ExportStructDef(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        has_late_exports = true
      _ => ()
    }
  }
  if not(has_late_exports) {
    return exports
  }
  for stmt in stmts {
    match stmt {
      @core.Stmt::Export(names~, ..) =>
        for name in names {
          if defined.contains(name) {
            exports[name] = true
          }
        }
      @core.Stmt::ReExport(names~, ..) =>
        for name in names {
          exports[name] = true
        }
      _ => ()
    }
  }
  exports
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
    "ArrayBuilder", "MapBuilder", "i32", "f32", "f64",
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
fn is_reserved_wasm_type_name(name : String) -> Bool {
  name == "i32" || name == "f32" || name == "f64"
}

///|
fn ensure_not_reserved_wasm_type_name(
  name : String,
  span : @core.Span,
) -> Unit raise TypeError {
  if is_reserved_wasm_type_name(name) {
    raise TypeError::BadTypeDef(
      message="reserved wasm type name: " + name,
      span~,
    )
  }
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
fn ensure_prelude_error_trait(env : TypeEnv) -> Unit raise TypeError {
  let span = @core.Span::empty(0)
  if not(env.has_trait("Error")) {
    register_trait_def(env, "Error", [], true, true, span)
  }
  if not(type_implements_trait(env, @core.Type::String, "Error")) {
    register_trait_impl(env, [], {}, "Error", @core.Type::String, span)
  }
}

///|
pub fn ensure_prelude_functions(
  env : TypeEnv,
  aliases : Map[String, @core.Ref],
) -> Unit raise TypeError {
  ensure_prelude_error_trait(env)
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
        {},
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
fn dedup_trait_bounds(bounds : Array[String]) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let out : Array[String] = []
  for bound in bounds {
    if not(seen.contains(bound)) {
      seen[bound] = true
      out.push(bound)
    }
  }
  out
}

///|
fn merge_trait_bounds(
  left : Array[String],
  right : Array[String],
) -> Array[String] {
  let out = left.copy()
  for bound in right {
    out.push(bound)
  }
  dedup_trait_bounds(out)
}

///|
fn declared_param_bounds(
  env : TypeEnv,
  param_ty : @core.Type,
  explicit_bounds : Array[String],
) -> Array[String] {
  let merged = dedup_trait_bounds(explicit_bounds)
  match resolve_type(env, param_ty) {
    @core.Type::Var(id) =>
      match env.var_trait_bounds.get(id) {
        Some(bounds) => merge_trait_bounds(merged, bounds)
        None => merged
      }
    _ => merged
  }
}

///|
fn add_var_trait_bounds(
  env : TypeEnv,
  id : Int,
  bounds : Array[String],
) -> Unit {
  if bounds.is_empty() {
    return
  }
  match env.var_trait_bounds.get(id) {
    Some(existing) =>
      env.var_trait_bounds[id] = merge_trait_bounds(existing, bounds)
    None => env.var_trait_bounds[id] = dedup_trait_bounds(bounds)
  }
}

///|
fn instantiate_scheme(env : TypeEnv, scheme : TypeScheme) -> @core.Type {
  if scheme.vars.is_empty() && scheme.effect_vars.is_empty() {
    return resolve_type(env, scheme.ty)
  }
  let mapping : Map[Int, @core.Type] = {}
  for id in scheme.vars {
    if scheme.num_vars.contains(id) {
      mapping[id] = fresh_num_var(env)
    } else {
      mapping[id] = fresh_type_var(env)
    }
  }
  if not(scheme.trait_bounds.is_empty()) {
    for id in scheme.vars {
      match mapping.get(id) {
        Some(@core.Type::Var(new_id)) =>
          match scheme.trait_bounds.get(id) {
            Some(bounds) => add_var_trait_bounds(env, new_id, bounds)
            None => ()
          }
        _ => ()
      }
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
            bounds: param.bounds,
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
          bounds: param.bounds,
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
          bounds: param.bounds,
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
          bounds: param.bounds,
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
          bounds: param.bounds,
        })
      }
      @core.Type::Func(params=out, ret=replace_num_type(ret, num_var), effects~)
    }
    _ => ty
  }
}

///|
/// Substitute type parameters (Type::Param) with their corresponding type variables
fn substitute_type_params(
  ty : @core.Type,
  mapping : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match mapping.get(name) {
        Some(var_ty) => var_ty
        None => ty // Keep as is if not in mapping
      }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type_params(arg, mapping))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type_params(item, mapping))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_params(item, mapping)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_params(inner, mapping))
    @core.Type::Map(inner) =>
      @core.Type::Map(substitute_type_params(inner, mapping))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type_params(inner, mapping))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_type_params(inner, mapping))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_params(item, mapping)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_params(param.ty, mapping),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=substitute_type_params(ret, mapping),
        effects~,
      )
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
fn trait_is_subtrait_inner(
  env : TypeEnv,
  sub_trait : String,
  super_trait : String,
  visiting : Map[String, Bool],
) -> Bool {
  if sub_trait == super_trait {
    return true
  }
  if visiting.contains(sub_trait) {
    return false
  }
  match env.get_trait_info(sub_trait) {
    Some(info) => {
      let next_visiting = visiting.copy()
      next_visiting[sub_trait] = true
      for parent in info.supertraits {
        if parent == super_trait {
          return true
        }
        if trait_is_subtrait_inner(env, parent, super_trait, next_visiting) {
          return true
        }
      }
      false
    }
    None => false
  }
}

///|
fn trait_is_subtrait(
  env : TypeEnv,
  sub_trait : String,
  super_trait : String,
) -> Bool {
  trait_is_subtrait_inner(env, sub_trait, super_trait, {})
}

///|
fn trait_bound_satisfied(
  env : TypeEnv,
  available : Array[String],
  required : String,
) -> Bool {
  for bound in available {
    if trait_is_subtrait(env, bound, required) {
      return true
    }
  }
  false
}

///|
fn ensure_traits_defined(
  env : TypeEnv,
  bounds : Array[String],
  span : @core.Span,
) -> Unit raise TypeError {
  let deduped = dedup_trait_bounds(bounds)
  for bound in deduped {
    if not(env.has_trait(bound)) {
      raise TypeError::BadTypeDef(message="unknown trait: " + bound, span~)
    }
  }
}

///|
fn register_trait_def(
  env : TypeEnv,
  name : String,
  supertraits : Array[String],
  open_impl : Bool,
  exported : Bool,
  span : @core.Span,
) -> Unit raise TypeError {
  if open_impl && not(exported) {
    raise TypeError::BadTypeDef(
      message="`open trait` is only allowed with export",
      span~,
    )
  }
  if env.has_trait(name) {
    raise TypeError::BadTypeDef(message="duplicate trait: " + name, span~)
  }
  let normalized_supertraits = dedup_trait_bounds(supertraits)
  for supertrait in normalized_supertraits {
    if supertrait == name {
      raise TypeError::BadTypeDef(
        message="trait cannot inherit itself: " + name,
        span~,
      )
    }
  }
  ensure_traits_defined(env, normalized_supertraits, span)
  env.set_trait_info(name, TraitDefInfo::{
    supertraits: normalized_supertraits,
    open_impl,
    is_local: true,
  })
}

///|
fn type_matches_impl_target(
  env : TypeEnv,
  pattern : @core.Type,
  actual : @core.Type,
  mapping : Map[String, @core.Type],
) -> Bool {
  let p = resolve_type(env, pattern)
  let a = resolve_type(env, actual)
  match p {
    @core.Type::Param(name) =>
      match mapping.get(name) {
        Some(bound_ty) => type_equal(env, bound_ty, a) catch { _ => false }
        None => {
          mapping[name] = a
          true
        }
      }
    @core.Type::Named(name=pn, args=pa) =>
      match a {
        @core.Type::Named(name=an, args=aa) =>
          if pn != an || pa.length() != aa.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<pa.length() {
              if not(type_matches_impl_target(env, pa[i], aa[i], mapping)) {
                ok = false
                break
              }
            }
            ok
          }
        _ => false
      }
    @core.Type::Tuple(ps) =>
      match a {
        @core.Type::Tuple(actual_items) =>
          if ps.length() != actual_items.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<ps.length() {
              if not(
                  type_matches_impl_target(env, ps[i], actual_items[i], mapping),
                ) {
                ok = false
                break
              }
            }
            ok
          }
        _ => false
      }
    @core.Type::Record(pf) =>
      match a {
        @core.Type::Record(af) =>
          if pf.length() != af.length() {
            false
          } else {
            let mut ok = true
            for name, p_ty in pf {
              match af.get(name) {
                Some(a_ty) =>
                  if not(type_matches_impl_target(env, p_ty, a_ty, mapping)) {
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
        _ => false
      }
    @core.Type::Array(inner) =>
      match a {
        @core.Type::Array(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::Map(inner) =>
      match a {
        @core.Type::Map(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::ArrayBuilder(inner) =>
      match a {
        @core.Type::ArrayBuilder(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::MapBuilder(inner) =>
      match a {
        @core.Type::MapBuilder(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::Variant(pf) =>
      match a {
        @core.Type::Variant(af) =>
          if pf.length() != af.length() {
            false
          } else {
            let mut ok = true
            for name, p_ty in pf {
              match af.get(name) {
                Some(a_ty) =>
                  if not(type_matches_impl_target(env, p_ty, a_ty, mapping)) {
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
        _ => false
      }
    @core.Type::Func(params=pp, ret=pr, ..) =>
      match a {
        @core.Type::Func(params=ap, ret=ar, ..) =>
          if pp.length() != ap.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<pp.length() {
              if pp[i].label != ap[i].label ||
                not(type_matches_impl_target(env, pp[i].ty, ap[i].ty, mapping)) {
                ok = false
                break
              }
            }
            ok && type_matches_impl_target(env, pr, ar, mapping)
          }
        _ => false
      }
    _ => type_equal(env, p, a) catch { _ => false }
  }
}

///|
fn type_implements_trait(
  env : TypeEnv,
  ty : @core.Type,
  trait_name : String,
) -> Bool {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Var(id) =>
      match env.var_trait_bounds.get(id) {
        Some(bounds) => trait_bound_satisfied(env, bounds, trait_name)
        None => false
      }
    _ => {
      if type_implements_trait_from_impls(
          env,
          resolved,
          env.trait_impls_for(trait_name),
        ) {
        return true
      }
      for impl_trait_name in env.trait_names() {
        if impl_trait_name == trait_name {
          continue
        }
        if not(trait_is_subtrait(env, impl_trait_name, trait_name)) {
          continue
        }
        if type_implements_trait_from_impls(
            env,
            resolved,
            env.trait_impls_for(impl_trait_name),
          ) {
          return true
        }
      }
      false
    }
  }
}

///|
fn type_implements_trait_from_impls(
  env : TypeEnv,
  resolved : @core.Type,
  impls : Array[TraitImplDef],
) -> Bool {
  for impl_def in impls {
    let mapping : Map[String, @core.Type] = {}
    if type_matches_impl_target(env, impl_def.target, resolved, mapping) {
      let mut ok = true
      for param in impl_def.type_params {
        match mapping.get(param) {
          Some(actual_ty) =>
            match impl_def.type_bounds.get(param) {
              Some(bounds) =>
                for bound in bounds {
                  if not(type_implements_trait(env, actual_ty, bound)) {
                    ok = false
                    break
                  }
                }
              None => ()
            }
          None => ()
        }
        if not(ok) {
          break
        }
      }
      if ok {
        return true
      }
    }
  }
  false
}

///|
fn ensure_type_satisfies_bounds(
  env : TypeEnv,
  ty : @core.Type,
  bounds : Array[String],
  span : @core.Span,
  context : String,
) -> Bool raise TypeError {
  let deduped = dedup_trait_bounds(bounds)
  if deduped.is_empty() {
    return true
  }
  ensure_traits_defined(env, deduped, span)
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Var(id) => {
      add_var_trait_bounds(env, id, deduped)
      true
    }
    _ => {
      for bound in deduped {
        if not(type_implements_trait(env, resolved, bound)) {
          raise TypeError::Mismatch(
            expected=@core.Type::Named(name=bound, args=[]),
            actual=resolved,
            span~,
            context=Some(context),
          )
        }
      }
      true
    }
  }
}

///|
fn register_trait_impl(
  env : TypeEnv,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  trait_name : String,
  target : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.has_trait(trait_name)) {
    raise TypeError::BadTypeDef(message="unknown trait: " + trait_name, span~)
  }
  if not(env.trait_is_local(trait_name)) && not(env.trait_is_open(trait_name)) {
    raise TypeError::BadTypeDef(message="trait is sealed: " + trait_name, span~)
  }
  ensure_unique_params(type_params, span)
  let normalized_type_bounds : Map[String, Array[String]] = {}
  for type_param in type_params {
    match type_bounds.get(type_param) {
      Some(bounds) => {
        let deduped = dedup_trait_bounds(bounds)
        ensure_traits_defined(env, deduped, span)
        normalized_type_bounds[type_param] = deduped
      }
      None => ()
    }
  }
  let normalized_target = resolve_type(env, target)
  let incoming = TraitImplDef::{
    type_params,
    type_bounds: normalized_type_bounds,
    target: normalized_target,
  }
  for impl_def in env.trait_impls_for(trait_name) {
    if trait_impls_overlap(env, impl_def, incoming) {
      raise TypeError::BadTypeDef(
        message="overlapping impl: " + trait_name,
        span~,
      )
    }
  }
  env.add_trait_impl(trait_name, incoming)
}

///|
fn instantiate_trait_impl_target(
  env : TypeEnv,
  impl_def : TraitImplDef,
) -> @core.Type {
  let mapping : Map[String, @core.Type] = {}
  for type_param in impl_def.type_params {
    let tv = fresh_type_var(env)
    mapping[type_param] = tv
    match tv {
      @core.Type::Var(id) =>
        match impl_def.type_bounds.get(type_param) {
          Some(bounds) => add_var_trait_bounds(env, id, bounds)
          None => ()
        }
      _ => ()
    }
  }
  substitute_type_params(impl_def.target, mapping)
}

///|
fn trait_impls_overlap(
  env : TypeEnv,
  left : TraitImplDef,
  right : TraitImplDef,
) -> Bool {
  let overlap_env = clone_env(env)
  let left_target = instantiate_trait_impl_target(overlap_env, left)
  let right_target = instantiate_trait_impl_target(overlap_env, right)
  let result : Result[Bool, TypeError] = try? unify_types(
    overlap_env, left_target, right_target,
  )
  match result {
    Ok(v) => v
    Err(_) => false
  }
}

///|
fn register_enum_def(
  env : TypeEnv,
  name : String,
  params : Array[String],
  ctors : Array[@core.TypeCtor],
  span : @core.Span,
) -> Unit raise TypeError {
  ensure_not_reserved_wasm_type_name(name, span)
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
  ensure_not_reserved_wasm_type_name(name, span)
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  ensure_unique_params(params, span)
  let normalized = normalize_type(env, target)
  env.set_type_alias(name, TypeAlias::{ name, params, target: normalized })
}

///|
fn register_struct_def(
  env : TypeEnv,
  name : String,
  params : Array[String],
  fields : Array[@core.StructField],
  span : @core.Span,
) -> Unit raise TypeError {
  ensure_not_reserved_wasm_type_name(name, span)
  if env.get_enum_def(name) is Some(_) ||
    env.get_type_alias(name) is Some(_) ||
    env.get_struct(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  ensure_unique_params(params, span)
  // Check for duplicate field names
  let seen : Map[String, Bool] = {}
  for field in fields {
    if seen.contains(field.name) {
      raise TypeError::BadTypeDef(
        message="duplicate field: " + field.name,
        span=field.span,
      )
    }
    seen[field.name] = true
  }
  // Convert fields
  let field_defs : Array[StructFieldDef] = []
  for field in fields {
    let normalized = normalize_type(env, field.ty)
    field_defs.push(StructFieldDef::{ name: field.name, ty: normalized })
  }
  env.set_struct(name, StructDef::{ name, params, fields: field_defs })
}

///|
fn type_struct_lit(
  env : TypeEnv,
  name : String,
  type_args : Array[@core.Type],
  fields : Array[@core.RecordFieldExpr],
  span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  match env.get_struct(name) {
    Some(struct_def) => {
      // Build type argument mapping
      let type_map : Map[String, @core.Type] = {}
      if type_args.length() > 0 {
        // Explicit type arguments
        if type_args.length() != struct_def.params.length() {
          raise TypeError::BadTypeDef(
            message="wrong number of type arguments for struct " + name,
            span~,
          )
        }
        for i, param in struct_def.params {
          type_map[param] = type_args[i]
        }
      }
      // Check each field
      let provided : Map[String, Bool] = {}
      for field in fields {
        if provided.contains(field.name) {
          raise TypeError::BadTypeDef(
            message="duplicate field: " + field.name,
            span=field.span,
          )
        }
        provided[field.name] = true
        match struct_def.get_field(field.name) {
          Some(field_def) => {
            let field_ty = type_expr_eff(
              env,
              field.expr,
              aliases,
              effects,
              allow_effect,
            )
            // Infer type params from field types first (before type check)
            if type_args.is_empty() {
              infer_type_params_from_field(
                env,
                field_def.ty,
                field_ty,
                type_map,
              )
            }
            // Now substitute and check
            let expected = substitute_type_params_by_name(
              field_def.ty,
              type_map,
            )
            if not(type_equal(env, expected, field_ty)) {
              raise TypeError::Mismatch(
                expected~,
                actual=field_ty,
                span=field.span,
                context=Some("struct field " + field.name),
              )
            }
          }
          None =>
            raise TypeError::BadTypeDef(
              message="struct " + name + " has no field: " + field.name,
              span=field.span,
            )
        }
      }
      // Check all required fields are provided
      for field_def in struct_def.fields {
        if not(provided.contains(field_def.name)) {
          raise TypeError::BadTypeDef(
            message="missing field: " + field_def.name,
            span~,
          )
        }
      }
      // Build result type
      let result_args : Array[@core.Type] = []
      for param in struct_def.params {
        match type_map.get(param) {
          Some(ty) => result_args.push(ty)
          None => result_args.push(fresh_type_var(env))
        }
      }
      @core.Type::Named(name~, args=result_args)
    }
    None => raise TypeError::UnknownName(name~, span~, suggestion=None)
  }
}

///|
fn infer_type_params_from_field(
  env : TypeEnv,
  expected : @core.Type,
  actual : @core.Type,
  type_map : Map[String, @core.Type],
) -> Unit {
  match expected {
    @core.Type::Param(param_name) =>
      if not(type_map.contains(param_name)) {
        type_map[param_name] = actual
      }
    @core.Type::Array(inner) =>
      match actual {
        @core.Type::Array(actual_inner) =>
          infer_type_params_from_field(env, inner, actual_inner, type_map)
        _ => ()
      }
    @core.Type::Tuple(items) =>
      match actual {
        @core.Type::Tuple(actual_items) =>
          for i, item in items {
            if i < actual_items.length() {
              infer_type_params_from_field(env, item, actual_items[i], type_map)
            }
          }
        _ => ()
      }
    @core.Type::Named(args~, ..) =>
      match actual {
        @core.Type::Named(args=actual_args, ..) =>
          for i, arg in args {
            if i < actual_args.length() {
              infer_type_params_from_field(env, arg, actual_args[i], type_map)
            }
          }
        _ => ()
      }
    _ => ()
  }
}

///|
fn substitute_type_params_by_name(
  ty : @core.Type,
  type_map : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match type_map.get(name) {
        Some(t) => t
        None => ty
      }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_params_by_name(inner, type_map))
    @core.Type::Tuple(items) => {
      let new_items : Array[@core.Type] = []
      for item in items {
        new_items.push(substitute_type_params_by_name(item, type_map))
      }
      @core.Type::Tuple(new_items)
    }
    @core.Type::Named(name~, args~) => {
      let new_args : Array[@core.Type] = []
      for arg in args {
        new_args.push(substitute_type_params_by_name(arg, type_map))
      }
      @core.Type::Named(name~, args=new_args)
    }
    @core.Type::Record(fields) => {
      let new_fields : Map[String, @core.Type] = {}
      for name, field_ty in fields {
        new_fields[name] = substitute_type_params_by_name(field_ty, type_map)
      }
      @core.Type::Record(new_fields)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let new_params : Array[@core.FuncParam] = []
      for param in params {
        new_params.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_params_by_name(param.ty, type_map),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=new_params,
        ret=substitute_type_params_by_name(ret, type_map),
        effects~,
      )
    }
    _ => ty
  }
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
    @core.Expr::Placeholder(span~, ..) =>
      // Placeholder should have been desugared to lambda; error if it reaches here
      raise TypeError::BadCall(
        message="placeholder _ can only be used in function arguments",
        span~,
      )
    @core.Expr::Call(name~, args~, span~, ..) =>
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
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let tuple_ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
      let resolved = resolve_type(env, tuple_ty)
      match resolved {
        @core.Type::Tuple(items) =>
          if index < 0 || index >= items.length() {
            raise TypeError::BadCall(
              message="tuple index \{index} out of bounds (length \{items.length()})",
              span~,
            )
          } else {
            items[index]
          }
        _ =>
          raise TypeError::Mismatch(
            expected=@core.Type::Tuple([]),
            actual=resolved,
            span~,
            context=Some("tuple index"),
          )
      }
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
    @core.Expr::StructLit(name~, type_args~, fields~, span~) =>
      type_struct_lit(
        env, name, type_args, fields, span, aliases, effects, allow_effect,
      )
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
      let mut has_bool_pat = false
      let mut covered_true = false
      let mut covered_false = false
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
                @core.Pat::Bool(value~, ..) => {
                  has_bool_pat = true
                  if value {
                    covered_true = true
                  } else {
                    covered_false = true
                  }
                }
                _ => ()
              }
            }
          @core.Pat::Bool(value~, ..) => {
            has_bool_pat = true
            if value {
              covered_true = true
            } else {
              covered_false = true
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
          @core.Type::Bool =>
            if not(has_bool_pat && covered_true && covered_false) {
              raise TypeError::NonExhaustiveMatch(span~)
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
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects=fn_effects,
      body~,
      span~
    ) => {
      // Create fresh type variables for each type parameter
      let type_param_vars : Map[String, @core.Type] = {}
      for tp in type_params {
        type_param_vars[tp] = fresh_type_var(env)
        match type_bounds.get(tp) {
          Some(bounds) => {
            let deduped = dedup_trait_bounds(bounds)
            ensure_traits_defined(env, deduped, span)
            match type_param_vars.get(tp) {
              Some(@core.Type::Var(id)) =>
                add_var_trait_bounds(env, id, deduped)
              _ => ()
            }
          }
          None => ()
        }
      }
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
      // Add type parameters as type aliases so inner functions can access them
      for tp in type_params {
        match type_param_vars.get(tp) {
          Some(ty) =>
            scope_env.set_type_alias(tp, TypeAlias::{
              name: tp,
              params: [],
              target: ty,
            })
          None => ()
        }
      }
      let resolved_params : Array[@core.FuncParam] = []
      for param in params {
        let param_ty_with_num = match num_var {
          Some(n) => replace_num_type(param.ty, n)
          None => param.ty
        }
        // Replace type parameters with their type variables
        let param_ty = substitute_type_params(
          param_ty_with_num, type_param_vars,
        )
        let resolved = normalize_type(env, param_ty)
        let _ = ensure_type_satisfies_bounds(
          env,
          resolved,
          param.bounds,
          span,
          "fn param " + param.name,
        )
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
          bounds: declared_param_bounds(env, resolved, param.bounds),
        })
      }
      let normalized_effects = normalize_effects(fn_effects, span)
      let fn_scope = effect_scope_from_list(normalized_effects)
      // Allow effects in function body if function declares effects
      let fn_allow_effect = allow_effect || normalized_effects.length() > 0
      let body_ty = type_block(
        scope_env, body, aliases, fn_scope, fn_allow_effect,
      )
      let resolved_effects = effect_set_to_atoms(
        effect_set_from_atoms(scope_env, normalized_effects),
      )
      let final_ret = match ret {
        Some(r) => {
          let ret_ty_with_num = match num_var {
            Some(n) => replace_num_type(r, n)
            None => r
          }
          // Replace type parameters with their type variables
          let ret_ty = substitute_type_params(ret_ty_with_num, type_param_vars)
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
      env.loop_depth += 1
      let body_ty_result : Result[@core.Type, TypeError] = try? type_block(
        env, body, aliases, effects, allow_effect,
      )
      env.loop_depth -= 1
      match body_ty_result {
        Ok(_) => ()
        Err(err) => raise err
      }
      @core.Type::Unit
    }
    @core.Expr::Break(span~) => {
      if env.loop_depth <= 0 {
        raise TypeError::BadCall(message="break used outside while loop", span~)
      }
      @core.Type::Unit
    }
    @core.Expr::Continue(span~) => {
      if env.loop_depth <= 0 {
        raise TypeError::BadCall(
          message="continue used outside while loop",
          span~,
        )
      }
      @core.Type::Unit
    }
    @core.Expr::Raise(value~, span~) => {
      let val_ty = type_expr_eff(env, value, aliases, effects, allow_effect)
      let _ = ensure_type_satisfies_bounds(
        env,
        val_ty,
        ["Error"],
        span,
        "raise",
      )
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Error")],
        "raise",
        span,
      )
      @core.Type::Never
    }
    @core.Expr::Await(expr~, span~) => {
      let inner_ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Async")],
        "await",
        span,
      )
      inner_ty
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = type_expr_eff(env, expr, aliases, effects, allow_effect)
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Async")],
        "yield",
        span,
      )
      @core.Type::Unit
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
  let trait_bounds : Map[Int, Array[String]] = {}
  for id in vars {
    match env.var_trait_bounds.get(id) {
      Some(bounds) => trait_bounds[id] = bounds.copy()
      None => ()
    }
  }
  TypeScheme::{ vars, num_vars, effect_vars, trait_bounds, ty: normalized }
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
    @core.Pat::Struct(name=struct_name, fields~, span~) =>
      match env.get_struct(struct_name) {
        Some(struct_def) => {
          // Create type argument mapping from scrutinee type
          let type_map : Map[String, @core.Type] = {}
          match scrutinee_ty {
            @core.Type::Named(args~, ..) =>
              for i, param in struct_def.params {
                if i < args.length() {
                  type_map[param] = args[i]
                }
              }
            _ => ()
          }
          for field in fields {
            match struct_def.get_field(field.name) {
              Some(field_def) => {
                let field_ty = substitute_type_params_by_name(
                  field_def.ty,
                  type_map,
                )
                collect_pattern_bindings_inner(env, out, field.pat, field_ty)
              }
              None =>
                raise TypeError::BadMatch(
                  message="struct " +
                    struct_name +
                    " has no field: " +
                    field.name,
                  span=field.span,
                )
            }
          }
        }
        None =>
          raise TypeError::BadMatch(
            message="unknown struct: " + struct_name,
            span~,
          )
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
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = name
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
      @core.Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, span~) => {
        register_trait_def(
          scope_env, name, supertraits, open_impl, exported, span,
        )
        last = @core.Type::Unit
      }
      @core.Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target~,
        span~
      ) => {
        register_trait_impl(
          scope_env, type_params, type_bounds, trait_name, target, span,
        )
        last = @core.Type::Unit
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        last = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
      }
      @core.Stmt::Import(spec~, source~, span~) => {
        let _ = spec
        let _ = source
        let _ = span
        last = @core.Type::Unit
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let scheme = type_let_expr(
          scope_env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        scope_env.set_scheme(name, scheme)
        last = scheme.ty
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        register_enum_def(scope_env, name, params, ctors, span)
        last = @core.Type::Unit
      }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
        register_type_alias(scope_env, name, params, target, span)
        last = @core.Type::Unit
      }
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        last = @core.Type::Unit
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_block(scope_env, body, aliases, effects, allow_effect)
        last = @core.Type::Unit
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_block(scope_env, body, aliases, effects, allow_effect)
        last = @core.Type::Unit
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        let scheme = TypeScheme::{
          vars: [],
          num_vars: [],
          effect_vars: [],
          trait_bounds: {},
          ty,
        }
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
            trait_bounds: {},
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
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        // Type check target[index] = value
        let _ = type_expr_eff(scope_env, target, aliases, effects, allow_effect)
        let _ = type_expr_eff(scope_env, index, aliases, effects, allow_effect)
        let _ = type_expr_eff(scope_env, value, aliases, effects, allow_effect)
        let _ = span
        last = @core.Type::Unit
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~) => {
        register_struct_def(scope_env, name, params, fields, span)
        last = @core.Type::Unit
      }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) => {
        register_struct_def(scope_env, name, params, fields, span)
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
fn ensure_eq_operand(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::String => ()
    @core.Type::Var(id) =>
      if is_num_var(env, id) {
        ()
      } else {
        match env.var_trait_bounds.get(id) {
          Some(bounds) =>
            if not(trait_bound_satisfied(env, bounds, "Eq")) {
              raise TypeError::Mismatch(
                expected=@core.Type::Named(name="Eq", args=[]),
                actual=resolved,
                span~,
                context=Some("argument"),
              )
            }
          None =>
            raise TypeError::Mismatch(
              expected=@core.Type::Named(name="Eq", args=[]),
              actual=resolved,
              span~,
              context=Some("argument"),
            )
        }
      }
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
fn ensure_ord_operand(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::String => ()
    @core.Type::Var(id) =>
      if is_num_var(env, id) {
        ()
      } else {
        match env.var_trait_bounds.get(id) {
          Some(bounds) =>
            if not(trait_bound_satisfied(env, bounds, "Ord")) {
              raise TypeError::Mismatch(
                expected=@core.Type::Named(name="Ord", args=[]),
                actual=resolved,
                span~,
                context=Some("argument"),
              )
            }
          None =>
            raise TypeError::Mismatch(
              expected=@core.Type::Named(name="Ord", args=[]),
              actual=resolved,
              span~,
              context=Some("argument"),
            )
        }
      }
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
fn variant_namespace_root_from_type(
  env : TypeEnv,
  fields : Map[String, @core.Type],
) -> String? {
  let mut found : String? = None
  for enum_name in env.enum_names() {
    match env.get_enum_def(enum_name) {
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
fn namespace_root_from_type(env : TypeEnv, ty : @core.Type) -> String? {
  match resolve_type(env, ty) {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::Named(name~, ..) => Some(name)
    @core.Type::Variant(fields) => variant_namespace_root_from_type(env, fields)
    _ => None
  }
}

///|
fn resolve_type_member_call_name(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> String? raise TypeError {
  if name.contains("::") || name.contains(".") {
    return None
  }
  let _ = call_span
  let mut recv_expr : @core.Expr? = None
  for arg in args {
    match arg.label {
      Some(_) => ()
      None => if recv_expr is None { recv_expr = Some(arg.expr) }
    }
  }
  match recv_expr {
    None => return None
    Some(expr) => {
      let recv_ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
      match namespace_root_from_type(env, recv_ty) {
        Some(root) => {
          let candidate = root + "::" + name
          match env.get(candidate) {
            Some(_) => Some(candidate)
            None => None
          }
        }
        None => None
      }
    }
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
  let lookup_name = match
    resolve_type_member_call_name(
      env, name, args, aliases, effects, allow_effect, call_span,
    ) {
    Some(candidate) => candidate
    None => name
  }
  match env.get(lookup_name) {
    Some(ty) =>
      match ty {
        @core.Type::Func(params~, ret~, effects=fn_effects) => {
          check_call_args(
            env, lookup_name, params, args, aliases, effects, allow_effect, call_span,
          )
          require_effects(env, effects, fn_effects, lookup_name, call_span)
          ret
        }
        _ =>
          // Name exists but isn't a function - try field access first
          match
            try_field_access(
              env, lookup_name, args, aliases, effects, allow_effect, call_span,
            ) {
            Some(field_ty) => field_ty
            None =>
              raise TypeError::BadCall(message=lookup_name, span=call_span)
          }
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "sh",
                  builtin_effects("sh"),
                  call_span,
                )
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
              "sh_lines" => {
                let pos_args = extract_positional_args(
                  args, "sh_lines", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="sh_lines", span=call_span)
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "sh_lines",
                  builtin_effects("sh_lines"),
                  call_span,
                )
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
                @core.Type::Array(@core.Type::String)
              }
              "sleep" => {
                let pos_args = extract_positional_args(args, "sleep", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="sleep", span=call_span)
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "sleep",
                  builtin_effects("sleep"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "threads_probe_wat" => {
                let pos_args = extract_positional_args(
                  args, "threads_probe_wat", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="threads_probe_wat",
                    span=call_span,
                  )
                }
                @core.Type::String
              }
              "threads_runtime_hints" => {
                let pos_args = extract_positional_args(
                  args, "threads_runtime_hints", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="threads_runtime_hints",
                    span=call_span,
                  )
                }
                let fields : Map[String, @core.Type] = {}
                fields["wasm_flags"] = @core.Type::Array(@core.Type::String)
                fields["wasi_flags"] = @core.Type::Array(@core.Type::String)
                fields["wasm_env"] = @core.Type::String
                fields["wasi_env"] = @core.Type::String
                @core.Type::Record(fields)
              }
              "threads_channel_new" => {
                let pos_args = extract_positional_args(
                  args, "threads_channel_new", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="threads_channel_new",
                    span=call_span,
                  )
                }
                let cap_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, cap_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=cap_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "threads_send" => {
                let pos_args = extract_positional_args(
                  args, "threads_send", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="threads_send",
                    span=call_span,
                  )
                }
                let channel_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, channel_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=channel_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let message_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, message_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=message_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "threads_recv" => {
                let pos_args = extract_positional_args(
                  args, "threads_recv", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="threads_recv",
                    span=call_span,
                  )
                }
                let channel_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, channel_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=channel_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "threads_spawn" => {
                let pos_args = extract_positional_args(
                  args, "threads_spawn", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="threads_spawn",
                    span=call_span,
                  )
                }
                let name_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, name_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=name_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let mailbox_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, mailbox_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=mailbox_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "threads_wait" => {
                let pos_args = extract_positional_args(
                  args, "threads_wait", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="threads_wait",
                    span=call_span,
                  )
                }
                let task_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, task_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=task_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "stdout_write_char" => {
                let pos_args = extract_positional_args(
                  args, "stdout_write_char", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="stdout_write_char",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdout_write_char",
                  builtin_effects("stdout_write_char"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "stdin_read_char" => {
                let pos_args = extract_positional_args(
                  args, "stdin_read_char", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="stdin_read_char",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdin_read_char",
                  builtin_effects("stdin_read_char"),
                  call_span,
                )
                @core.Type::Int
              }
              "stdout_write_stream" => {
                let pos_args = extract_positional_args(
                  args, "stdout_write_stream", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="stdout_write_stream",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdout_write_stream",
                  builtin_effects("stdout_write_stream"),
                  call_span,
                )
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
              "stdin_read_stream" => {
                let pos_args = extract_positional_args(
                  args, "stdin_read_stream", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="stdin_read_stream",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdin_read_stream",
                  builtin_effects("stdin_read_stream"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_from_char_code" => {
                let pos_args = extract_positional_args(
                  args, "string_from_char_code", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_from_char_code",
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
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "array_builder",
                  [],
                  call_span,
                )
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "array_builder_push",
                  [],
                  call_span,
                )
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "array_builder_freeze",
                  [],
                  call_span,
                )
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "map_builder",
                  [],
                  call_span,
                )
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "map_builder_set",
                  [],
                  call_span,
                )
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
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "map_builder_freeze",
                  [],
                  call_span,
                )
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
              "string_utf8_length" => {
                let pos_args = extract_positional_args(
                  args, "string_utf8_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_utf8_length",
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
              "string_utf16_length" => {
                let pos_args = extract_positional_args(
                  args, "string_utf16_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_utf16_length",
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
              "string_unicode_length" => {
                let pos_args = extract_positional_args(
                  args, "string_unicode_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_unicode_length",
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
              "__lshift"
              | "__rshift"
              | "__bit_and"
              | "__bit_or"
              | "__bit_xor" => {
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
                if not(type_equal(env, a, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("bit operation"),
                  )
                }
                if not(type_equal(env, b, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("bit operation"),
                  )
                }
                @core.Type::Int
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
                ensure_eq_operand(env, a, pos_args[0].span())
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
                ensure_ord_operand(env, a, pos_args[0].span())
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
              "int_to_float" | "f32_convert_i32_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Int,
                  @core.Type::Float,
                )
              "int_to_double" | "f64_convert_i32_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Int,
                  @core.Type::Double,
                )
              "float_to_int" | "i32_trunc_f32_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Float,
                  @core.Type::Int,
                )
              "float_to_double" | "f64_promote_f32" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Float,
                  @core.Type::Double,
                )
              "double_to_int" | "i32_trunc_f64_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Double,
                  @core.Type::Int,
                )
              "double_to_float" | "f32_demote_f64" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Double,
                  @core.Type::Float,
                )
              "i32_shr_u" => {
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
                if not(type_equal(env, a, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("bit operation"),
                  )
                }
                if not(type_equal(env, b, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("bit operation"),
                  )
                }
                @core.Type::Int
              }
              "f32_neg" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "f32_neg",
                  @core.Type::Float,
                  @core.Type::Float,
                )
              "f64_neg" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "f64_neg",
                  @core.Type::Double,
                  @core.Type::Double,
                )
              "i32_load" | "i32_load8_u" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "i32_store" | "i32_store8" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, value_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "f32_load" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Float
              }
              "f64_load" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Double
              }
              "f32_store" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, value_ty, @core.Type::Float)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Float,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "f64_store" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, value_ty, @core.Type::Double)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Double,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
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
              _ =>
                // Try to interpret as field access: x(p) where p is a record/struct
                // and x is a field name
                match
                  try_field_access(
                    env, name, args, aliases, effects, allow_effect, call_span,
                  ) {
                  Some(ty) => ty
                  None => raise TypeError::BadCall(message=name, span=call_span)
                }
            }
          }
      }
  }
}

///|
fn try_field_access(
  env : TypeEnv,
  field_name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type? raise TypeError {
  // Field access is desugared from p.field to field(p)
  // So we expect exactly one positional argument
  let pos_args = extract_positional_args(args, field_name, call_span)
  if pos_args.length() != 1 {
    return None
  }
  let arg_ty = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
  let resolved = resolve_type(env, arg_ty)
  // Try Record field access
  match resolved {
    @core.Type::Record(fields) =>
      match fields.get(field_name) {
        Some(field_ty) => return Some(field_ty)
        None => return None
      }
    @core.Type::Named(name~, args=type_args) =>
      // Try Struct field access
      match env.get_struct(name) {
        Some(struct_def) =>
          match struct_def.get_field(field_name) {
            Some(field_def) => {
              // Substitute type parameters (resolve type args first)
              let type_map : Map[String, @core.Type] = {}
              for i, param in struct_def.params {
                if i < type_args.length() {
                  type_map[param] = resolve_type(env, type_args[i])
                }
              }
              let result_ty = substitute_type_params_by_name(
                field_def.ty,
                type_map,
              )
              return Some(result_ty)
            }
            None => return None
          }
        None => return None
      }
    _ => return None
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
    @core.Expr::TupleIndex(expr~, ..) =>
      is_non_expansive_expr(env, expr, aliases)
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
    @core.Expr::Call(name~, args~, span~, ..) => {
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
  if rec && name == "_" {
    raise TypeError::BadRec(
      message="wildcard binding cannot be recursive",
      span~,
    )
  }
  if rec {
    match expr {
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects=fn_effects,
        body~,
        span=fn_span
      ) =>
        match ret {
          None => raise TypeError::BadRec(message="missing return type", span~)
          Some(r) => {
            let type_param_vars : Map[String, @core.Type] = {}
            for tp in type_params {
              type_param_vars[tp] = fresh_type_var(env)
              match type_bounds.get(tp) {
                Some(bounds) => {
                  let deduped = dedup_trait_bounds(bounds)
                  ensure_traits_defined(env, deduped, fn_span)
                  match type_param_vars.get(tp) {
                    Some(@core.Type::Var(id)) =>
                      add_var_trait_bounds(env, id, deduped)
                    _ => ()
                  }
                }
                None => ()
              }
            }
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
            let scope_env = clone_env(env)
            for tp in type_params {
              match type_param_vars.get(tp) {
                Some(ty) =>
                  scope_env.set_type_alias(tp, TypeAlias::{
                    name: tp,
                    params: [],
                    target: ty,
                  })
                None => ()
              }
            }
            let resolved_params : Array[@core.FuncParam] = []
            for param in params {
              let param_ty_with_num = match num_var {
                Some(n) => replace_num_type(param.ty, n)
                None => param.ty
              }
              let param_ty = substitute_type_params(
                param_ty_with_num, type_param_vars,
              )
              let resolved = normalize_type(env, param_ty)
              let _ = ensure_type_satisfies_bounds(
                env,
                resolved,
                param.bounds,
                fn_span,
                "fn param " + param.name,
              )
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
                bounds: declared_param_bounds(env, resolved, param.bounds),
              })
            }
            let ret_ty_with_num = match num_var {
              Some(n) => replace_num_type(r, n)
              None => r
            }
            let ret_ty = substitute_type_params(
              ret_ty_with_num, type_param_vars,
            )
            let resolved_ret = normalize_type(env, ret_ty)
            let normalized_effects = normalize_effects(fn_effects, fn_span)
            let provisional_fn_ty = @core.Type::Func(
              params=resolved_params,
              ret=resolved_ret,
              effects=normalized_effects,
            )
            scope_env.set(name, provisional_fn_ty)
            scope_env.active_rec_fn = Some(name)
            scope_env.active_rec_fn_has_type_params = type_params.length() > 0
            let fn_scope = effect_scope_from_list(normalized_effects)
            let fn_allow_effect = allow_effect ||
              normalized_effects.length() > 0
            let body_ty = type_block(
              scope_env, body, aliases, fn_scope, fn_allow_effect,
            )
            if not(type_equal(scope_env, resolved_ret, body_ty)) {
              raise TypeError::Mismatch(
                expected=resolved_ret,
                actual=body_ty,
                span=fn_span,
                context=Some("fn return"),
              )
            }
            let resolved_effects = effect_set_to_atoms(
              effect_set_from_atoms(scope_env, normalized_effects),
            )
            let final_params : Array[@core.FuncParam] = []
            for param in resolved_params {
              final_params.push(@core.FuncParam::{
                name: param.name,
                label: param.label,
                ty: resolve_type(scope_env, param.ty),
                bounds: param.bounds,
              })
            }
            let final_ty = @core.Type::Func(
              params=final_params,
              ret=resolve_type(scope_env, resolved_ret),
              effects=resolved_effects,
            )
            generalize(env, final_ty)
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
        TypeScheme::{
          vars: [],
          num_vars: [],
          effect_vars: [],
          trait_bounds: {},
          ty: normalized,
        }
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
/// Check if a lambda expression has placeholder types that need inference
fn has_infer_placeholder(params : Array[@core.FuncParam]) -> Bool {
  for param in params {
    if param.ty.is_infer_placeholder() {
      return true
    }
  }
  false
}

///|
/// Type an argument expression with optional expected type context
fn type_arg_with_context(
  env : TypeEnv,
  expr : @core.Expr,
  expected : @core.Type?,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  match expr {
    @core.Expr::Fn(params=fn_params, ..) =>
      match expected {
        Some(exp_ty) if has_infer_placeholder(fn_params) =>
          type_lambda_with_context(
            env, expr, exp_ty, aliases, effects, allow_effect,
          )
        _ => type_expr_eff(env, expr, aliases, effects, allow_effect)
      }
    _ => type_expr_eff(env, expr, aliases, effects, allow_effect)
  }
}

///|
/// Type a lambda with contextual type information from the expected parameter type
fn type_lambda_with_context(
  env : TypeEnv,
  expr : @core.Expr,
  expected : @core.Type,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  match expr {
    @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~, ..) => {
      // Resolve the expected type first
      let resolved_expected = resolve_type(env, expected)
      match resolved_expected {
        @core.Type::Func(params=expected_params, ret=expected_ret, ..) => {
          let scope_env = clone_env(env)
          let resolved_params : Array[@core.FuncParam] = []
          for i in 0..<params.length() {
            let param = params[i]
            // Use expected type if param type is placeholder
            let param_ty = if param.ty.is_infer_placeholder() &&
              i < expected_params.length() {
              // Resolve the expected param type (might still be Var, that's ok)
              resolve_type(env, expected_params[i].ty)
            } else {
              normalize_type(env, param.ty)
            }
            let _ = ensure_type_satisfies_bounds(
              env,
              param_ty,
              param.bounds,
              span,
              "lambda param " + param.name,
            )
            let binding_ty = if param.label == @core.ParamLabel::Optional {
              @core.Type::Named(name="Option", args=[param_ty])
            } else {
              param_ty
            }
            scope_env.set(param.name, binding_ty)
            resolved_params.push(@core.FuncParam::{
              name: param.name,
              label: param.label,
              ty: param_ty,
              bounds: declared_param_bounds(env, param_ty, param.bounds),
            })
          }
          let normalized_effects = normalize_effects(fn_effects, span)
          let fn_scope = effect_scope_from_list(normalized_effects)
          let body_ty = type_block(
            scope_env, body, aliases, fn_scope, allow_effect,
          )
          let resolved_effects = effect_set_to_atoms(
            effect_set_from_atoms(scope_env, normalized_effects),
          )
          // Verify or infer return type
          let final_ret = match ret {
            Some(r) => {
              let resolved = normalize_type(env, r)
              if not(type_equal(env, resolved, body_ty)) {
                raise TypeError::Mismatch(
                  expected=resolved,
                  actual=body_ty,
                  span~,
                  context=Some("lambda return"),
                )
              }
              resolved
            }
            None => body_ty
          }
          // Unify return type with expected (this binds type vars)
          let _ = unify_types(env, expected_ret, final_ret)
          // After body type checking, params might have been unified with concrete types
          // Re-resolve params to get final types
          let final_params : Array[@core.FuncParam] = []
          for p in resolved_params {
            let final_ty = resolve_type(env, p.ty)
            final_params.push(@core.FuncParam::{
              name: p.name,
              label: p.label,
              ty: final_ty,
              bounds: p.bounds,
            })
          }
          @core.Type::Func(
            params=final_params,
            ret=final_ret,
            effects=resolved_effects,
          )
        }
        @core.Type::Var(id) => {
          // Expected type is itself a type variable
          // Type the lambda normally and unify
          let lambda_ty = type_expr_eff(
            env, expr, aliases, effects, allow_effect,
          )
          let _ = bind_var(env, id, lambda_ty)
          lambda_ty
        }
        _ =>
          // Expected type is not a function, fall back to normal typing
          type_expr_eff(env, expr, aliases, effects, allow_effect)
      }
    }
    _ => type_expr_eff(env, expr, aliases, effects, allow_effect)
  }
}

///|
fn is_active_polymorphic_recursive_call(
  env : TypeEnv,
  callee_name : String,
) -> Bool {
  match env.active_rec_fn {
    Some(active) => active == callee_name && env.active_rec_fn_has_type_params
    None => false
  }
}

///|
fn check_call_args(
  env : TypeEnv,
  callee_name : String,
  params : Array[@core.FuncParam],
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> Unit raise TypeError {
  // Build positional params list first for bidirectional inference
  let positional : Array[@core.FuncParam] = []
  for param in params {
    if param.label == @core.ParamLabel::Positional {
      positional.push(param)
    }
  }
  // Type arguments with contextual information for lambdas
  let arg_types : Array[ArgType] = []
  let mut pos_idx = 0
  for arg in args {
    let ty = match arg.label {
      None => {
        // Positional argument - check if it's a lambda needing inference
        let expected_ty : @core.Type? = if pos_idx < positional.length() {
          Some(positional[pos_idx].ty)
        } else {
          None
        }
        pos_idx += 1
        type_arg_with_context(
          env,
          arg.expr,
          expected_ty,
          aliases,
          effects,
          allow_effect,
        )
      }
      Some(label) => {
        // Labeled argument - find expected type
        let mut expected_ty : @core.Type? = None
        for param in params {
          if param.label != @core.ParamLabel::Positional && param.name == label {
            expected_ty = Some(param.ty)
            break
          }
        }
        type_arg_with_context(
          env,
          arg.expr,
          expected_ty,
          aliases,
          effects,
          allow_effect,
        )
      }
    }
    arg_types.push(ArgType::{ label: arg.label, ty, span: arg.span })
  }
  // Now check types match
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
          if is_active_polymorphic_recursive_call(env, callee_name) {
            raise TypeError::BadRec(
              message="polymorphic recursion is unsupported",
              span=arg.span,
            )
          }
          raise TypeError::Mismatch(
            expected=argument_mismatch_expected_type(env, param.ty, arg.ty),
            actual=resolve_type(env, arg.ty),
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
              if is_active_polymorphic_recursive_call(env, callee_name) {
                raise TypeError::BadRec(
                  message="polymorphic recursion is unsupported",
                  span=arg.span,
                )
              }
              raise TypeError::Mismatch(
                expected=argument_mismatch_expected_type(env, param.ty, arg.ty),
                actual=resolve_type(env, arg.ty),
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
fn argument_mismatch_expected_type(
  env : TypeEnv,
  expected : @core.Type,
  actual : @core.Type,
) -> @core.Type {
  let resolved_expected = resolve_type(env, expected)
  let resolved_actual = resolve_type(env, actual)
  match resolved_expected {
    @core.Type::Var(id) =>
      match env.var_trait_bounds.get(id) {
        Some(bounds) => {
          let deduped = dedup_trait_bounds(bounds)
          for bound in deduped {
            if not(type_implements_trait(env, resolved_actual, bound)) {
              return @core.Type::Named(name=bound, args=[])
            }
          }
          resolved_expected
        }
        None => resolved_expected
      }
    _ => resolved_expected
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
                match env.get_struct(name) {
                  Some(struct_def) => {
                    if struct_def.params.length() != normalized_args.length() {
                      raise TypeError::BadTypeDef(
                        message="type arity: " + name,
                        span=unknown_span(),
                      )
                    }
                    // For struct types, return Named type with normalized args
                    @core.Type::Named(name~, args=normalized_args)
                  }
                  None =>
                    raise TypeError::UnknownType(
                      name~,
                      span=unknown_span(),
                      suggestion=find_type_suggestion(env, name),
                    )
                }
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
          bounds: param.bounds,
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
pub enum ApiVersionBump {
  Patch
  Minor
  Major
} derive(Show, Eq)

///|
fn semver_init() -> ApiSemver {
  ApiSemver::{ major: 1, minor: 0, patch: 0 }
}

///|
fn semver_apply(version : ApiSemver, bump : ApiVersionBump) -> ApiSemver {
  match bump {
    ApiVersionBump::Patch =>
      ApiSemver::{
        major: version.major,
        minor: version.minor,
        patch: version.patch + 1,
      }
    ApiVersionBump::Minor =>
      ApiSemver::{ major: version.major, minor: version.minor + 1, patch: 0 }
    ApiVersionBump::Major =>
      ApiSemver::{ major: version.major + 1, minor: 0, patch: 0 }
  }
}

///|
fn effect_atom_key(effect : @core.EffectAtom) -> String {
  match effect {
    @core.EffectAtom::Const(name) => "C:" + name
    @core.EffectAtom::Var(name) => "V:" + name
  }
}

///|
fn effects_subset(
  small : Array[@core.EffectAtom],
  large : Array[@core.EffectAtom],
) -> Bool {
  let large_keys : Map[String, Bool] = {}
  for effect in large {
    large_keys[effect_atom_key(effect)] = true
  }
  for effect in small {
    if not(large_keys.contains(effect_atom_key(effect))) {
      return false
    }
  }
  true
}

///|
fn trait_bounds_subset(
  env : TypeEnv,
  small : Array[String],
  large : Array[String],
) -> Bool {
  let required = dedup_trait_bounds(small)
  let available = dedup_trait_bounds(large)
  for bound in required {
    if not(trait_bound_satisfied(env, available, bound)) {
      return false
    }
  }
  true
}

///|
fn try_type_equal(env : TypeEnv, left : @core.Type, right : @core.Type) -> Bool {
  let result : Result[Bool, TypeError] = try? type_equal(env, left, right)
  match result {
    Ok(v) => v
    Err(_) => false
  }
}

///|
pub fn is_type_subtype(
  env : TypeEnv,
  sub : @core.Type,
  sup : @core.Type,
) -> Bool {
  let left = resolve_type(env, sub)
  let right = resolve_type(env, sup)
  if try_type_equal(env, left, right) {
    return true
  }
  match (left, right) {
    (_, @core.Type::Named(name=trait_name, args=[])) if env.has_trait(
        trait_name,
      ) => type_implements_trait(env, left, trait_name)
    (@core.Type::Tuple(sub_items), @core.Type::Tuple(sup_items)) =>
      if sub_items.length() != sup_items.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<sub_items.length() {
          if not(is_type_subtype(env, sub_items[i], sup_items[i])) {
            ok = false
            break
          }
        }
        ok
      }
    (@core.Type::Record(sub_fields), @core.Type::Record(sup_fields)) => {
      let mut ok = true
      for name, sup_ty in sup_fields {
        match sub_fields.get(name) {
          Some(sub_ty) =>
            if not(is_type_subtype(env, sub_ty, sup_ty)) {
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
    (@core.Type::Array(sub_inner), @core.Type::Array(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::Map(sub_inner), @core.Type::Map(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::ArrayBuilder(sub_inner), @core.Type::ArrayBuilder(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::MapBuilder(sub_inner), @core.Type::MapBuilder(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (
      @core.Type::Func(params=sub_params, ret=sub_ret, effects=sub_effects),
      @core.Type::Func(params=sup_params, ret=sup_ret, effects=sup_effects),
    ) =>
      if sub_params.length() != sup_params.length() {
        false
      } else if not(effects_subset(sub_effects, sup_effects)) {
        false
      } else {
        let mut ok = true
        for i in 0..<sub_params.length() {
          let sub_param = sub_params[i]
          let sup_param = sup_params[i]
          if sub_param.label != sup_param.label {
            ok = false
            break
          }
          if sub_param.label != @core.ParamLabel::Positional &&
            sub_param.name != sup_param.name {
            ok = false
            break
          }
          if not(trait_bounds_subset(env, sub_param.bounds, sup_param.bounds)) {
            ok = false
            break
          }
          // Function parameter types are contravariant:
          // new <: old requires old_param <: new_param
          if not(is_type_subtype(env, sup_param.ty, sub_param.ty)) {
            ok = false
            break
          }
        }
        ok && is_type_subtype(env, sub_ret, sup_ret)
      }
    _ => false
  }
}

///|
pub fn classify_function_api_change(
  env : TypeEnv,
  old_ty : @core.Type,
  new_ty : @core.Type,
) -> ApiVersionBump {
  let check_minor_env = clone_env(env)
  if is_type_subtype(check_minor_env, new_ty, old_ty) {
    let check_patch_env = clone_env(env)
    if is_type_subtype(check_patch_env, old_ty, new_ty) {
      ApiVersionBump::Patch
    } else {
      ApiVersionBump::Minor
    }
  } else {
    ApiVersionBump::Major
  }
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
  if not(
      trait_bounds_subset(env, a.bounds, b.bounds) &&
      trait_bounds_subset(env, b.bounds, a.bounds),
    ) {
    return false
  }
  unify_types(env, a.ty, b.ty)
}

///|
fn bind_var(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  let resolved = resolve_type(env, ty)
  let required_bounds = match env.var_trait_bounds.get(id) {
    Some(bounds) => bounds
    None => []
  }
  if is_num_var(env, id) {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          mark_num_var(env, other)
          add_var_trait_bounds(env, other, required_bounds)
          env.subs[id] = resolved
          true
        }
      @core.Type::Int | @core.Type::Float | @core.Type::Double => {
        for bound in required_bounds {
          if not(type_implements_trait(env, resolved, bound)) {
            return false
          }
        }
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
          add_var_trait_bounds(env, other, required_bounds)
          env.subs[id] = resolved
          true
        }
      _ =>
        if occurs_in(env, id, resolved) {
          false
        } else {
          for bound in required_bounds {
            if not(type_implements_trait(env, resolved, bound)) {
              return false
            }
          }
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
