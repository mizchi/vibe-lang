///|
/// Types and values for xsh
pub(all) enum ParamLabel {
  Positional
  Required
  Optional
} derive(Show, Eq)

///|
pub fn ParamLabel::is_positional(self : ParamLabel) -> Bool {
  match self {
    ParamLabel::Positional => true
    _ => false
  }
}

///|
pub(all) struct FuncParam {
  name : String
  label : ParamLabel
  ty : Type
} derive(Show, Eq)

///|
pub(all) enum EffectAtom {
  Const(String)
  Var(String)
} derive(Show, Eq)

///|
pub(all) enum Type {
  Int
  Float
  Double
  Bool
  String
  Path
  Unit
  Tuple(Array[Type])
  Record(Map[String, Type])
  Array(Type)
  Map(Type)
  ArrayBuilder(Type)
  MapBuilder(Type)
  Variant(Map[String, Type])
  Named(name~ : String, args~ : Array[Type])
  Param(String)
  Var(Int)
  Func(params~ : Array[FuncParam], ret~ : Type, effects~ : Array[EffectAtom])
  Never
} derive(Show, Eq)

///|
/// Check if a type is a placeholder for inference (Unit is used as placeholder)
pub fn Type::is_infer_placeholder(self : Type) -> Bool {
  match self {
    Type::Unit => true
    _ => false
  }
}

///|
pub(all) struct Path {
  raw : String
} derive(Show, Eq)

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
pub(all) struct FnValue {
  params : Array[FuncParam]
  body : Module
  env : Map[String, String]
  addr : String?
  pure : Bool
} derive(Show, Eq)

///|
pub(all) enum Value {
  Int(Int)
  Float(Float)
  Double(Double)
  Bool(Bool)
  String(String)
  Path(Path)
  Unit
  Tuple(Array[Value])
  Record(Map[String, Value])
  Array(Array[Value])
  Map(Map[String, Value])
  ArrayBuilder(Array[Value])
  MapBuilder(Map[String, Value])
  Fn(FnValue)
} derive(Show, Eq)
