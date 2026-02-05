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
    Expr::Int(value~, span~) => {
      let _ = value
      span
    }
    Expr::Float(value~, span~) => {
      let _ = value
      span
    }
    Expr::Double(value~, span~) => {
      let _ = value
      span
    }
    Expr::Bool(value~, span~) => {
      let _ = value
      span
    }
    Expr::String(value~, span~) => {
      let _ = value
      span
    }
    Expr::Ident(name~, span~) => {
      let _ = name
      span
    }
    Expr::Call(name~, args~, span~) => {
      let _ = name
      let _ = args
      span
    }
    Expr::Tuple(items~, span~) => {
      let _ = items
      span
    }
    Expr::Record(fields~, span~) => {
      let _ = fields
      span
    }
    Expr::Array(items~, span~) => {
      let _ = items
      span
    }
    Expr::Map(fields~, span~) => {
      let _ = fields
      span
    }
    Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = cond
      let _ = then_body
      let _ = else_body
      span
    }
    Expr::Block(body~, span~) => {
      let _ = body
      span
    }
    Expr::Match(scrutinee~, arms~, span~) => {
      let _ = scrutinee
      let _ = arms
      span
    }
    Expr::Do(body~, span~) => {
      let _ = body
      span
    }
    Expr::Try(try_body~, catch_body~, span~) => {
      let _ = try_body
      let _ = catch_body
      span
    }
    Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      span
    }
  }
}

///|
pub fn Pat::span(self : Pat) -> Span {
  match self {
    Pat::Wildcard(span~) => span
    Pat::Bind(name~, span~) => {
      let _ = name
      span
    }
    Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = args
      span
    }
    Pat::Tuple(items~, span~) => {
      let _ = items
      span
    }
    Pat::Record(fields~, span~) => {
      let _ = fields
      span
    }
    Pat::Int(value~, span~) => {
      let _ = value
      span
    }
    Pat::Float(value~, span~) => {
      let _ = value
      span
    }
    Pat::Double(value~, span~) => {
      let _ = value
      span
    }
    Pat::Bool(value~, span~) => {
      let _ = value
      span
    }
    Pat::String(value~, span~) => {
      let _ = value
      span
    }
  }
}

///|
pub fn Stmt::span(self : Stmt) -> Span {
  match self {
    Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = expr
      span
    }
    Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = ctors
      span
    }
    Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      span
    }
    Stmt::Expr(expr~, span~) => {
      let _ = expr
      span
    }
    Stmt::Flake(raw~, span~) => {
      let _ = raw
      span
    }
    Stmt::Alias(name~, target~, span~) => {
      let _ = name
      let _ = target
      span
    }
    Stmt::Import(path~, span~) => {
      let _ = path
      span
    }
    Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      span
    }
  }
}
