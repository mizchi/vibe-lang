///|
/// @core.Type checking for vibe
pub(all) enum TopLevelPurityTier {
  Pure
  StateLocal
  Impure
} derive(Debug, Eq)

///|
pub impl Show for TopLevelPurityTier with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
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
  PropertyAccessAmbiguous(
    property_name~ : String,
    function_name~ : String,
    function_error~ : String,
    field_type~ : @core.Type,
    span~ : @core.Span
  )
  BadRec(message~ : String, span~ : @core.Span)
  BadMatch(message~ : String, span~ : @core.Span)
  NonExhaustiveMatch(missing~ : Array[String], span~ : @core.Span)
  BadTypeDef(message~ : String, span~ : @core.Span)
  TraitSealed(trait_name~ : String, span~ : @core.Span)
  TraitImplOverlap(
    trait_name~ : String,
    existing_target~ : @core.Type,
    incoming_target~ : @core.Type,
    span~ : @core.Span
  )
  EffectGuardNotSatisfied(
    operation~ : String,
    missing_effect~ : String?,
    span~ : @core.Span
  )
  ScopedRefEscape(context~ : String, span~ : @core.Span)
  TopLevelLetMut(name~ : String, span~ : @core.Span)
  TopLevelUnhandledEffect(
    operation~ : String,
    missing_effect~ : String?,
    span~ : @core.Span
  )
} derive(Debug, Eq)

///|
pub impl Show for TypeError with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
fn suggestion_hint(suggestion : String?) -> String? {
  match suggestion {
    Some(name) => Some("did you mean `" + name + "`?")
    None => None
  }
}

///|
/// Mismatch hint based on the context string. ADR-0045: when a trait bound
/// is the failure mode (the witness embedded `no impl `Eq` for `Foo``),
/// surface `derive(Eq)` as the typical fix so users do not have to know
/// the trait registration mechanics.
fn mismatch_hint(context : String?) -> String? {
  match context {
    Some(ctx) =>
      if ctx.contains("no impl `Eq`") {
        Some(
          "annotate the type with `derive(Eq)` or add `impl Eq for <type>` to give it an Eq instance",
        )
      } else if ctx.contains("no impl `Hash`") {
        Some("add `derive(Hash)` or `impl Hash for <type>`")
      } else if ctx.contains("no impl `Ord`") {
        Some("add `derive(Ord)` or `impl Ord for <type>`")
      } else {
        None
      }
    None => None
  }
}

///|
fn effect_not_allowed_hint(name : String) -> String? {
  if name == "Error" {
    Some(
      "declare `with {Error}` or handle with `handle { ... } with Error { Throw(...) => ... }`",
    )
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
fn effect_guard_hint(_operation : String, missing_effect : String?) -> String? {
  match missing_effect {
    Some(effect_name) => effect_not_allowed_hint(effect_name)
    None => None
  }
}

///|
fn effect_guard_note(_operation : String, missing_effect : String?) -> String? {
  match missing_effect {
    Some(effect_name) =>
      Some("missing effect declaration: `" + effect_name + "`")
    None => None
  }
}

///|
fn scoped_ref_escape_hint(_context : String) -> String {
  "keep `Ref[T]` inside local scope and return a pure value instead"
}

///|
fn scoped_ref_escape_note(context : String) -> String {
  "disallowed escape position: " + context
}

///|
fn bad_type_def_hint(message : String) -> String? {
  if message.has_prefix("handle is missing handler for `") {
    Some(
      "add the missing `Op(...) => ...` arm for this effect, or keep the `Result` boundary outside the handled block",
    )
  } else if message.has_prefix("undefined effect `") {
    Some(
      "declare the effect with `effect Name { ... }`, or prefer `Result[T, E]` in library/core flows and keep `Error` at adapter boundaries",
    )
  } else {
    None
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
        severity: None,
        code: None,
      }
    TypeError::UnknownType(name~, span~, suggestion~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "unknown type: " + name,
        span: Some(span),
        hint: suggestion_hint(suggestion),
        note: None,
        severity: None,
        code: None,
      }
    TypeError::DuplicateDecl(name~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "duplicate declaration: " + name,
        span: Some(span),
        hint: None,
        note: None,
        severity: None,
        code: None,
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
        hint: mismatch_hint(context),
        note: Some(
          "expected: " +
          expected.to_string() +
          "\nactual: " +
          actual.to_string(),
        ),
        severity: None,
        code: None,
      }
    }
    TypeError::BadCall(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: format_bad_call(message),
        span: Some(span),
        hint: bad_call_hint(message),
        note: None,
        severity: None,
        code: None,
      }
    TypeError::PropertyAccessAmbiguous(
      property_name~,
      function_name~,
      function_error~,
      field_type~,
      span~
    ) =>
      @core.Diagnostic::{
        stage: "type",
        message: "ambiguous postfix/property access: `" + property_name + "`",
        span: Some(span),
        hint: Some(
          "use `" +
          function_name +
          "(...)` for function-call semantics, or rename/qualify conflicting `" +
          property_name +
          "` symbols to keep field-access semantics",
        ),
        note: Some(
          "candidate(function): `" +
          function_name +
          "` -> " +
          function_error +
          "\n" +
          "candidate(field): receiver field `" +
          property_name +
          "` has type " +
          field_type.to_string() +
          "\n" +
          "resolution order: function call is checked before field-access fallback",
        ),
        severity: None,
        code: None,
      }
    TypeError::BadRec(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: format_bad_rec(message),
        span: Some(span),
        hint: None,
        note: None,
        severity: None,
        code: None,
      }
    TypeError::BadMatch(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: format_bad_match(message),
        span: Some(span),
        hint: None,
        note: None,
        severity: None,
        code: None,
      }
    TypeError::NonExhaustiveMatch(missing~, span~) => {
      let note : String? = if missing.length() > 0 {
        let names = missing
          .iter()
          .fold(init="", fn(acc, name) {
            if acc == "" {
              name
            } else {
              acc + ", " + name
            }
          })
        Some("missing patterns: " + names)
      } else {
        None
      }
      @core.Diagnostic::{
        stage: "type",
        message: "non-exhaustive match",
        span: Some(span),
        hint: Some("add the missing patterns or a wildcard `_` arm"),
        note,
        severity: None,
        code: None,
      }
    }
    TypeError::BadTypeDef(message~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "type definition: " + message,
        span: Some(span),
        hint: bad_type_def_hint(message),
        note: None,
        severity: None,
        code: None,
      }
    TypeError::TraitSealed(trait_name~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "[TROP001] trait is sealed: " + trait_name,
        span: Some(span),
        hint: Some(
          "define `" +
          trait_name +
          "` as `export open trait` in the source module to allow external impls",
        ),
        note: None,
        severity: None,
        code: None,
      }
    TypeError::TraitImplOverlap(
      trait_name~,
      existing_target~,
      incoming_target~,
      span~
    ) =>
      @core.Diagnostic::{
        stage: "type",
        message: "[TROP003] overlapping impl: " +
        trait_name +
        " for " +
        incoming_target.to_string(),
        span: Some(span),
        hint: Some(
          "narrow the impl target or bounds so only one impl can match each concrete type",
        ),
        note: Some(
          "conflicts with existing impl: " +
          trait_name +
          " for " +
          existing_target.to_string(),
        ),
        severity: None,
        code: None,
      }
    TypeError::EffectGuardNotSatisfied(operation~, missing_effect~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "effect requirements not satisfied: `" + operation + "`",
        span: Some(span),
        hint: effect_guard_hint(operation, missing_effect),
        note: effect_guard_note(operation, missing_effect),
        severity: None,
        code: None,
      }
    TypeError::ScopedRefEscape(context~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "scoped Ref[T] cannot escape: " + context,
        span: Some(span),
        hint: Some(scoped_ref_escape_hint(context)),
        note: Some(scoped_ref_escape_note(context)),
        severity: None,
        code: None,
      }
    TypeError::TopLevelLetMut(name~, span~) =>
      @core.Diagnostic::{
        stage: "type",
        message: "`let mut` is not allowed at the top level",
        span: Some(span),
        hint: Some("use `let` instead, or move mutable state into a function"),
        note: Some("top-level bindings must be immutable: `" + name + "`"),
        severity: None,
        code: None,
      }
    TypeError::TopLevelUnhandledEffect(operation~, missing_effect~, span~) => {
      let effect_name = match missing_effect {
        Some(name) => name
        None => "effect"
      }
      @core.Diagnostic::{
        stage: "type",
        message: "top-level expression has unhandled effect: `" +
        operation +
        "`",
        span: Some(span),
        hint: Some(
          "wrap with `handle { ... } with " +
          effect_name +
          " { ... => ... }` or move into a function with `with {" +
          effect_name +
          "}`",
        ),
        note: Some("missing effect: `" + effect_name + "`"),
        severity: None,
        code: None,
      }
    }
  }
}

///|
fn format_bad_call(message : String) -> String {
  match message {
    "missing positional args" => "not enough arguments"
    "too many positional args" => "too many arguments"
    "placeholder _ can only be used in function arguments" => message
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
fn bad_call_hint(message : String) -> String? {
  if message == "placeholder _ can only be used in function arguments" {
    Some(
      "use `_` only in call arguments (e.g. `map(xs, _ + 1)`), or rewrite as an explicit lambda `(x) -> ...`",
    )
  } else if message == "resume used outside handle arm" {
    Some(
      "use `resume(...)` only inside `handle { ... } with Effect { Op(...) => ... }` arms",
    )
  } else if message == "resume used outside effect arm" {
    Some(
      "`resume(...)` is only valid in effect arms like `Op(...) => ...`; `Error` boundary arms should return a fallback value directly",
    )
  } else {
    None
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
    TypeError::PropertyAccessAmbiguous(
      property_name~,
      function_name~,
      function_error~,
      field_type~,
      span~
    ) =>
      TypeError::PropertyAccessAmbiguous(
        property_name~,
        function_name~,
        function_error~,
        field_type=resolve_type(env, field_type),
        span~,
      )
    TypeError::TraitImplOverlap(
      trait_name~,
      existing_target~,
      incoming_target~,
      span~
    ) =>
      TypeError::TraitImplOverlap(
        trait_name~,
        existing_target=resolve_type(env, existing_target),
        incoming_target=resolve_type(env, incoming_target),
        span~,
      )
    _ => self
  }
}
