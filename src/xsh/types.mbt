///| Types and values for xsh

pub enum Type {
  Int
  Bool
  String
  Path
  Unit
  Tuple(Array[Type])
  Record(Map[String, Type])
} derive(Show, Eq)

///|
pub struct Path {
  raw : String
} derive(Show, Eq)

///|
pub fn Path::new(raw : String) -> Path {
  Path::{ raw: @fs.normalize_path(raw) }
}

///|
pub fn Path::as_string(self : Path) -> String {
  self.raw
}

///|
pub enum Value {
  Int(Int)
  Bool(Bool)
  String(String)
  Path(Path)
  Unit
  Tuple(Array[Value])
  Record(Map[String, Value])
} derive(Show, Eq)
