///|
/// Types and values for vibe
pub(all) enum ParamLabel {
  Positional
  Variadic
  Required
  Optional
} derive(Debug, Eq)

///|
pub fn ParamLabel::is_positional(self : ParamLabel) -> Bool {
  match self {
    ParamLabel::Positional => true
    ParamLabel::Variadic => true
    _ => false
  }
}

///|
pub(all) struct FuncParam {
  name : String
  label : ParamLabel
  ty : Type
  bounds : Array[String]
} derive(Debug, Eq)

///|
pub(all) enum EffectAtom {
  Const(String)
  Var(String)
} derive(Debug, Eq)

///|
pub(all) enum Type {
  Int
  Float
  Double
  Bool
  Char
  String
  Path
  PromptText
  Unit
  /// Type-inference placeholder emitted by the parser for unannotated fn params
  /// and `_`-sugar lambda params. Always replaced with a fresh type variable
  /// early in `type_fn_literal`; must not survive past the checker.
  Infer
  Tuple(Array[Type])
  Record(Map[String, Type])
  Array(Type)
  Map(Type, Type)
  Set(Type)
  ArrayBuilder(Type)
  MapBuilder(Type, Type)
  StringBuilder
  Bytes
  V128
  Variant(Map[String, Type])
  Named(name~ : String, args~ : Array[Type])
  Param(String)
  Var(Int)
  Func(params~ : Array[FuncParam], ret~ : Type, effects~ : Array[EffectAtom])
  Never
} derive(Debug, Eq)

///|
pub impl Show for Type with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
/// Check if a type is a placeholder for inference
pub fn Type::is_infer_placeholder(self : Type) -> Bool {
  match self {
    Type::Infer => true
    _ => false
  }
}

///|
pub(all) struct Path {
  raw : String
} derive(Debug, Eq)

///|
pub fn Path::new(raw : String) -> Path {
  let normalized = @path.Path(raw).normalize().to_string()
  let resolved = if normalized.has_prefix("/") {
    normalized
  } else {
    "/" + normalized
  }
  Path::{ raw: resolved }
}

///|
pub fn Path::as_string(self : Path) -> String {
  self.raw
}

///|
pub(all) struct PromptText {
  content : String
} derive(Debug, Eq)

///|
pub fn PromptText::new(content : String) -> PromptText {
  PromptText::{ content, }
}

///|
pub fn PromptText::as_string(self : PromptText) -> String {
  self.content
}

///|
pub(all) struct FnValue {
  params : Array[FuncParam]
  body : Module
  env : Map[String, String]
  addr : String?
  pure : Bool
} derive(Eq)

///|
/// Continuation for effect handlers (ADR-0021 Phase 0.5)
/// Carries the state needed to resume a handled body from a perform site
pub(all) struct ContinuationValue {
  site_key : String
  body : Module
  arms : Array[MatchArm]
} derive(Eq)

///|
pub impl Show for ContinuationValue with fn output(_self, logger) {
  logger.write_string("<continuation>")
}

///|
pub impl Show for FnValue with fn output(self, logger) {
  logger.write_string("<fn(")
  for i, param in self.params {
    if i > 0 {
      logger.write_string(", ")
    }
    logger.write_string(param.name)
    logger.write_string(": ")
    logger.write_string(format_type_compact(param.ty))
  }
  logger.write_string(")>")
}

///|
fn format_type_compact(ty : Type) -> String {
  match ty {
    Type::Int => "Int"
    Type::Float => "Float"
    Type::Double => "Double"
    Type::Bool => "Bool"
    Type::Char => "Char"
    Type::String => "String"
    Type::Path => "Path"
    Type::PromptText => "PromptText"
    Type::Unit => "Unit"
    Type::Infer => "_"
    Type::Never => "Never"
    Type::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(")
      for i, item in items {
        if i > 0 {
          buf.write_string(", ")
        }
        buf.write_string(format_type_compact(item))
      }
      buf.write_string(")")
      buf.to_string()
    }
    Type::Record(fields) => {
      let buf = StringBuilder::new()
      buf.write_string("{")
      let mut first = true
      for name, ty in fields {
        if !first {
          buf.write_string(", ")
        }
        first = false
        buf.write_string(name)
        buf.write_string(": ")
        buf.write_string(format_type_compact(ty))
      }
      buf.write_string("}")
      buf.to_string()
    }
    Type::Array(inner) => "Array[" + format_type_compact(inner) + "]"
    Type::Set(inner) => "Set[" + format_type_compact(inner) + "]"
    Type::Map(key, value) =>
      "Map[" +
      format_type_compact(key) +
      ", " +
      format_type_compact(value) +
      "]"
    Type::ArrayBuilder(inner) =>
      "ArrayBuilder[" + format_type_compact(inner) + "]"
    Type::MapBuilder(key, value) =>
      "MapBuilder[" +
      format_type_compact(key) +
      ", " +
      format_type_compact(value) +
      "]"
    Type::StringBuilder => "StringBuilder"
    Type::Bytes => "Bytes"
    Type::V128 => "V128"
    Type::Variant(_) => "Variant"
    Type::Named(name~, args~) =>
      if args.length() == 0 {
        name
      } else {
        let buf = StringBuilder::new()
        buf.write_string(name)
        buf.write_string("[")
        for i, arg in args {
          if i > 0 {
            buf.write_string(", ")
          }
          buf.write_string(format_type_compact(arg))
        }
        buf.write_string("]")
        buf.to_string()
      }
    Type::Param(name) => name
    Type::Var(id) => "?" + id.to_string()
    Type::Func(params~, ret~, effects~) => {
      let buf = StringBuilder::new()
      buf.write_string("(")
      for i, param in params {
        if i > 0 {
          buf.write_string(", ")
        }
        buf.write_string(format_type_compact(param.ty))
      }
      buf.write_string(") -> ")
      buf.write_string(format_type_compact(ret))
      if effects.length() > 0 {
        buf.write_string(" with {")
        for i, effect in effects {
          if i > 0 {
            buf.write_string(", ")
          }
          match effect {
            EffectAtom::Const(name) => buf.write_string(name)
            EffectAtom::Var(name) => buf.write_string(name)
          }
        }
        buf.write_string("}")
      }
      buf.to_string()
    }
  }
}

///|
pub(all) enum Value {
  Int(Int64)
  Float(Float)
  Double(Double)
  Bool(Bool)
  Char(Char)
  String(String)
  Path(Path)
  PromptText(PromptText)
  Unit
  Tuple(Array[Value])
  Record(Map[String, Value])
  Array(Array[Value])
  Map(Map[String, Value])
  Set(Map[String, Value])
  ArrayBuilder(Array[Value])
  MapBuilder(Map[String, Value])
  StringBuilder(Array[String])
  Bytes(Array[Byte])
  Fn(FnValue)
  /// Continuation value for effect handlers (ADR-0021)
  /// When called with a value, resumes the handled body from the perform site
  Continuation(ContinuationValue)
} derive(Eq)

///|
pub impl Show for Value with fn output(self, logger) {
  match self {
    Value::Int(n) => logger.write_string(n.to_string())
    Value::Float(n) => logger.write_string(n.to_string())
    Value::Double(n) => logger.write_string(@fp.double_to_string(n))
    Value::Bool(b) => logger.write_string(if b { "true" } else { "false" })
    Value::Char(c) => {
      logger.write_string("'")
      logger.write_string(c.to_string())
      logger.write_string("'")
    }
    Value::String(s) => {
      logger.write_string("\"")
      logger.write_string(s)
      logger.write_string("\"")
    }
    Value::Path(p) => {
      logger.write_string("path(\"")
      logger.write_string(p.raw)
      logger.write_string("\")")
    }
    Value::PromptText(pt) => {
      logger.write_string("prompt(\"")
      logger.write_string(pt.content)
      logger.write_string("\")")
    }
    Value::Unit => logger.write_string("()")
    Value::Tuple(items) => {
      logger.write_string("(")
      for i, item in items {
        if i > 0 {
          logger.write_string(", ")
        }
        item.output(logger)
      }
      logger.write_string(")")
    }
    Value::Record(fields) => {
      logger.write_string("{")
      let mut first = true
      for name, value in fields {
        if !first {
          logger.write_string(", ")
        }
        first = false
        logger.write_string(name)
        logger.write_string(": ")
        value.output(logger)
      }
      logger.write_string("}")
    }
    Value::Array(items) => {
      logger.write_string("[")
      for i, item in items {
        if i > 0 {
          logger.write_string(", ")
        }
        item.output(logger)
      }
      logger.write_string("]")
    }
    Value::Map(fields) => {
      logger.write_string("{|")
      let mut first = true
      for key, value in fields {
        if !first {
          logger.write_string(", ")
        }
        first = false
        logger.write_string("\"")
        logger.write_string(key)
        logger.write_string("\": ")
        value.output(logger)
      }
      logger.write_string("|}")
    }
    Value::Set(items) => {
      logger.write_string("Set{")
      let mut first = true
      for key, _ in items {
        if !first {
          logger.write_string(", ")
        }
        first = false
        logger.write_string(key)
      }
      logger.write_string("}")
    }
    Value::ArrayBuilder(items) => {
      logger.write_string("[..builder ")
      for i, item in items {
        if i > 0 {
          logger.write_string(", ")
        }
        item.output(logger)
      }
      logger.write_string("]")
    }
    Value::MapBuilder(fields) => {
      logger.write_string("{|..builder ")
      let mut first = true
      for key, value in fields {
        if !first {
          logger.write_string(", ")
        }
        first = false
        logger.write_string("\"")
        logger.write_string(key)
        logger.write_string("\": ")
        value.output(logger)
      }
      logger.write_string("|}")
    }
    Value::StringBuilder(chunks) => {
      logger.write_string("StringBuilder(")
      for i, chunk in chunks {
        if i > 0 {
          logger.write_string(", ")
        }
        logger.write_string("\"")
        logger.write_string(chunk)
        logger.write_string("\"")
      }
      logger.write_string(")")
    }
    Value::Bytes(data) => {
      logger.write_string("Bytes([")
      for i, b in data {
        if i > 0 {
          logger.write_string(", ")
        }
        logger.write_string(b.to_int().to_string())
      }
      logger.write_string("])")
    }
    Value::Fn(fn_value) => fn_value.output(logger)
    Value::Continuation(k) => k.output(logger)
  }
}

///|
pub fn Value::is_mutable_builder(self : Value) -> Bool {
  match self {
    Value::Array(_)
    | Value::ArrayBuilder(_)
    | Value::MapBuilder(_)
    | Value::StringBuilder(_)
    | Value::Bytes(_) => true
    _ => false
  }
}
