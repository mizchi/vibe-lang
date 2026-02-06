///|
/// AST types for xsh
pub(all) struct Module {
  stmts : Array[Stmt]
} derive(Show, Eq)

///|
pub(all) struct Ref {
  name : String
  hash_prefix : String?
} derive(Show, Eq)

///|
pub(all) enum AliasTarget {
  Module(Ref)
  Name(String)
} derive(Show, Eq)

///|
pub(all) enum Pat {
  Wildcard(span~ : Span)
  Bind(name~ : String, span~ : Span)
  Ctor(name~ : String, args~ : Array[Pat], span~ : Span)
  Tuple(items~ : Array[Pat], span~ : Span)
  Record(fields~ : Array[RecordFieldPat], span~ : Span)
  Int(value~ : Int, span~ : Span)
  Float(value~ : Float, span~ : Span)
  Double(value~ : Double, span~ : Span)
  Bool(value~ : Bool, span~ : Span)
  String(value~ : String, span~ : Span)
  Or(pats~ : Array[Pat], span~ : Span)
} derive(Show, Eq)

///|
pub fn is_ctor_name(name : String) -> Bool {
  if name.length() == 0 {
    false
  } else {
    let chars = name.to_array()
    let c = chars[0]
    c >= 'A' && c <= 'Z'
  }
}

///|
pub(all) struct RecordFieldPat {
  name : String
  pat : Pat
  span : Span
} derive(Show, Eq)

///|
pub(all) struct MatchArm {
  pat : Pat
  cond : Expr?
  expr : Expr
  span : Span
} derive(Show, Eq)

///|
pub(all) struct TypeCtor {
  name : String
  args : Array[Type]
  span : Span
} derive(Show, Eq)

///|
pub(all) enum Stmt {
  Let(rec~ : Bool, name~ : String, expr~ : Expr, span~ : Span)
  EnumDef(
    name~ : String,
    params~ : Array[String],
    ctors~ : Array[TypeCtor],
    span~ : Span
  )
  TypeAlias(
    name~ : String,
    params~ : Array[String],
    target~ : Type,
    span~ : Span
  )
  Expr(expr~ : Expr, span~ : Span)
  Flake(raw~ : String, span~ : Span)
  Alias(name~ : String, target~ : AliasTarget, span~ : Span)
  Import(path~ : String, span~ : Span)
  Test(name~ : String?, body~ : Module, span~ : Span)
  LetMut(name~ : String, expr~ : Expr, span~ : Span)
  Assign(name~ : String, expr~ : Expr, span~ : Span)
  LetPat(pat~ : Pat, expr~ : Expr, span~ : Span)
} derive(Show, Eq)

///|
pub(all) enum Expr {
  Int(value~ : Int, span~ : Span)
  Float(value~ : Float, span~ : Span)
  Double(value~ : Double, span~ : Span)
  Bool(value~ : Bool, span~ : Span)
  String(value~ : String, span~ : Span)
  Ident(name~ : String, span~ : Span)
  Call(name~ : String, args~ : Array[CallArg], span~ : Span)
  Tuple(items~ : Array[Expr], span~ : Span)
  Record(fields~ : Array[RecordFieldExpr], span~ : Span)
  Array(items~ : Array[Expr], span~ : Span)
  Map(fields~ : Array[MapFieldExpr], span~ : Span)
  If(cond~ : Expr, then_body~ : Module, else_body~ : Module, span~ : Span)
  Block(body~ : Module, span~ : Span)
  Match(scrutinee~ : Expr, arms~ : Array[MatchArm], span~ : Span)
  Do(body~ : Module, span~ : Span)
  Try(try_body~ : Module, catch_body~ : Module, span~ : Span)
  Fn(
    params~ : Array[FuncParam],
    ret~ : Type?,
    effects~ : Array[EffectAtom],
    body~ : Module,
    span~ : Span
  )
  While(cond~ : Expr, body~ : Module, span~ : Span)
  Raise(value~ : Expr, span~ : Span)
} derive(Show, Eq)

///|
pub(all) struct RecordFieldExpr {
  name : String
  expr : Expr
  span : Span
} derive(Show, Eq)

///|
pub(all) struct MapFieldExpr {
  key : String
  expr : Expr
  span : Span
} derive(Show, Eq)

///|
pub(all) struct CallArg {
  label : String?
  expr : Expr
  span : Span
} derive(Show, Eq)

///|
pub fn Expr::span(self : Expr) -> Span {
  match self {
    Expr::Int(span~, ..)
    | Expr::Float(span~, ..)
    | Expr::Double(span~, ..)
    | Expr::Bool(span~, ..)
    | Expr::String(span~, ..)
    | Expr::Ident(span~, ..)
    | Expr::Call(span~, ..)
    | Expr::Tuple(span~, ..)
    | Expr::Record(span~, ..)
    | Expr::Array(span~, ..)
    | Expr::Map(span~, ..)
    | Expr::If(span~, ..)
    | Expr::Block(span~, ..)
    | Expr::Match(span~, ..)
    | Expr::Do(span~, ..)
    | Expr::Try(span~, ..)
    | Expr::Fn(span~, ..)
    | Expr::While(span~, ..)
    | Expr::Raise(span~, ..) => span
  }
}

///|
pub fn Pat::span(self : Pat) -> Span {
  match self {
    Pat::Wildcard(span~)
    | Pat::Bind(span~, ..)
    | Pat::Ctor(span~, ..)
    | Pat::Tuple(span~, ..)
    | Pat::Record(span~, ..)
    | Pat::Int(span~, ..)
    | Pat::Float(span~, ..)
    | Pat::Double(span~, ..)
    | Pat::Bool(span~, ..)
    | Pat::String(span~, ..)
    | Pat::Or(span~, ..) => span
  }
}

///|
pub fn Stmt::span(self : Stmt) -> Span {
  match self {
    Stmt::Let(span~, ..)
    | Stmt::EnumDef(span~, ..)
    | Stmt::TypeAlias(span~, ..)
    | Stmt::Expr(span~, ..)
    | Stmt::Flake(span~, ..)
    | Stmt::Alias(span~, ..)
    | Stmt::Import(span~, ..)
    | Stmt::Test(span~, ..)
    | Stmt::LetMut(span~, ..)
    | Stmt::Assign(span~, ..)
    | Stmt::LetPat(span~, ..) => span
  }
}
