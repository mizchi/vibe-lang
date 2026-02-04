///|
/// AST types for xsh
pub struct Module {
  stmts : Array[Stmt]
} derive(Show, Eq)

///|
pub struct Ref {
  name : String
  hash_prefix : String?
} derive(Show, Eq)

///|
pub enum AliasTarget {
  Module(Ref)
  Name(String)
} derive(Show, Eq)

///|
pub enum Pat {
  Wildcard
  Bind(String)
  Ctor(name~ : String, args~ : Array[Pat])
  Tuple(Array[Pat])
  Record(Array[RecordFieldPat])
  Int(Int)
  Bool(Bool)
  String(String)
} derive(Show, Eq)

///|
fn is_ctor_name(name : String) -> Bool {
  if name.length() == 0 {
    false
  } else {
    let chars = name.to_array()
    let c = chars[0]
    c >= 'A' && c <= 'Z'
  }
}

///|
pub struct RecordFieldPat {
  name : String
  pat : Pat
} derive(Show, Eq)

///|
pub struct MatchArm {
  pat : Pat
  cond : Expr?
  expr : Expr
} derive(Show, Eq)

///|
pub struct TypeCtor {
  name : String
  args : Array[Type]
} derive(Show, Eq)

///|
pub enum Stmt {
  Let(rec~ : Bool, name~ : String, expr~ : Expr)
  EnumDef(name~ : String, params~ : Array[String], ctors~ : Array[TypeCtor])
  TypeAlias(name~ : String, params~ : Array[String], target~ : Type)
  Expr(expr~ : Expr)
  Flake(raw~ : String)
  Alias(name~ : String, target~ : AliasTarget)
  Import(path~ : String)
  Test(name~ : String?, body~ : Module)
} derive(Show, Eq)

///|
pub enum Expr {
  Int(Int)
  Bool(Bool)
  String(String)
  Ident(String)
  Call(name~ : String, args~ : Array[CallArg])
  Tuple(Array[Expr])
  Record(Array[RecordFieldExpr])
  Array(Array[Expr])
  Map(Array[MapFieldExpr])
  If(cond~ : Expr, then_body~ : Module, else_body~ : Module)
  Block(body~ : Module)
  Match(scrutinee~ : Expr, arms~ : Array[MatchArm])
  Do(body~ : Module)
  Try(try_body~ : Module, catch_body~ : Module)
  Fn(
    params~ : Array[FuncParam],
    ret~ : Type?,
    effects~ : Array[EffectAtom],
    body~ : Module
  )
} derive(Show, Eq)

///|
pub struct RecordFieldExpr {
  name : String
  expr : Expr
} derive(Show, Eq)

///|
pub struct MapFieldExpr {
  key : String
  expr : Expr
} derive(Show, Eq)

///|
pub struct CallArg {
  label : String?
  expr : Expr
} derive(Show, Eq)
