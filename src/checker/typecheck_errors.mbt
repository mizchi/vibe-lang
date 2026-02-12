///|
/// @core.Type checking for vibe
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
