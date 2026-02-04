///|
/// Types and values for xsh
pub enum ParamLabel {
  Positional
  Required
  Optional
} derive(Show, Eq)

///|
pub struct FuncParam {
  name : String
  label : ParamLabel
  ty : Type
} derive(Show, Eq)

///|
pub enum Type {
  Int
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
  Func(params~ : Array[FuncParam], ret~ : Type)
} derive(Show, Eq)

///|
pub struct Path {
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
pub struct FnValue {
  params : Array[FuncParam]
  body : Module
  env : Map[String, String]
  addr : String?
  pure : Bool
} derive(Show, Eq)

///|
pub enum Value {
  Int(Int)
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
