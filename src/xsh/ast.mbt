///| AST types for xsh

pub struct Module {
  stmts : Array[Stmt]
} derive(Show, Eq)

///|
pub struct Ref {
  name : String
  hash_prefix : String?
} derive(Show, Eq)

///|
pub enum Pat {
  Wildcard
  Bind(String)
  Tuple(Array[Pat])
  Record(Array[RecordFieldPat])
  Int(Int)
  Bool(Bool)
  String(String)
} derive(Show, Eq)

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
pub enum Stmt {
  Let(name~ : String, expr~ : Expr)
  Expr(expr~ : Expr)
  Flake(raw~ : String)
  Alias(name~ : String, target~ : Ref)
  Import(path~ : String)
  Test(name~ : String?, body~ : Module)
} derive(Show, Eq)

///|
pub enum Expr {
  Int(Int)
  Bool(Bool)
  String(String)
  Ident(String)
  Call(name~ : String, args~ : Array[Expr])
  Tuple(Array[Expr])
  Record(Array[RecordFieldExpr])
  If(cond~ : Expr, then_body~ : Module, else_body~ : Module)
  Block(body~ : Module)
  Match(scrutinee~ : Expr, arms~ : Array[MatchArm])
  Do(body~ : Module)
} derive(Show, Eq)

///|
pub struct RecordFieldExpr {
  name : String
  expr : Expr
} derive(Show, Eq)
