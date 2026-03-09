///|
/// AST types for vibe
pub(all) struct Module {
  stmts : Array[Stmt]
} derive(Show, Eq)

///|
pub(all) struct Ref {
  name : String
  hash_prefix : String?
} derive(Show, Eq)

///|
pub(all) enum Pat {
  Wildcard(span~ : Span)
  Bind(name~ : String, span~ : Span)
  Ctor(name~ : String, args~ : Array[Pat], span~ : Span)
  Tuple(items~ : Array[Pat], span~ : Span)
  Record(fields~ : Array[RecordFieldPat], span~ : Span)
  Struct(name~ : String, fields~ : Array[RecordFieldPat], span~ : Span)
  Int(value~ : Int64, span~ : Span)
  Float(value~ : Float, span~ : Span)
  Double(value~ : Double, span~ : Span)
  Bool(value~ : Bool, span~ : Span)
  Char(value~ : Char, span~ : Span)
  String(value~ : String, span~ : Span)
  Or(pats~ : Array[Pat], span~ : Span)
} derive(Show, Eq)

///|
pub fn is_ctor_name(name : String) -> Bool {
  if name.length() == 0 {
    false
  } else if name.contains("::") || name.contains(".") {
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
pub(all) struct StructField {
  name : String
  ty : Type
  span : Span
} derive(Show, Eq)

///|
/// Import item kind for explicit import namespaces.
pub(all) enum ImportKind {
  Value
  Type
  Trait
  Module
} derive(Show, Eq)

///|
/// Import item: `foo`, `foo as bar`, `type Foo`, or `trait Eq`
pub(all) struct ImportItem {
  kind : ImportKind
  name : String
  rename : String? // alias name if using `as`
} derive(Show, Eq)

///|
/// Import specification: only named imports allowed
/// import ./path.vibe { foo, bar as b }
pub(all) struct ImportSpec {
  items : Array[ImportItem]
} derive(Show, Eq)

///|
/// Module reference: path, content hash, or lock-managed ref
pub(all) enum ModuleRef {
  Path(path~ : String) // ./foo/bar.vibe
  Hash(hash~ : String) // #abc12345
  Version(name~ : String) // version@main
  Symbol(name~ : String) // symbol@std/math
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
  TraitDef(
    name~ : String,
    supertraits~ : Array[String],
    open_impl~ : Bool,
    exported~ : Bool,
    span~ : Span
  )
  TraitImpl(
    type_params~ : Array[String],
    type_bounds~ : Map[String, Array[String]],
    trait_name~ : String,
    target~ : Type,
    span~ : Span
  )
  Expr(expr~ : Expr, span~ : Span)
  Import(spec~ : ImportSpec, source~ : ModuleRef, span~ : Span)
  Test(name~ : String?, body~ : Module, span~ : Span)
  Bench(name~ : String?, body~ : Module, span~ : Span)
  LetMut(name~ : String, expr~ : Expr, span~ : Span)
  ExternLet(name~ : String, ty~ : Type, span~ : Span)
  Assign(name~ : String, expr~ : Expr, span~ : Span)
  IndexAssign(target~ : Expr, index~ : Expr, value~ : Expr, span~ : Span)
  LetPat(pat~ : Pat, expr~ : Expr, span~ : Span)
  LetPatElse(pat~ : Pat, expr~ : Expr, else_body~ : Module, span~ : Span)
  // Export statements
  ExportLet(rec~ : Bool, name~ : String, expr~ : Expr, span~ : Span)
  InternalExportLet(rec~ : Bool, name~ : String, expr~ : Expr, span~ : Span)
  ExportEnumDef(
    name~ : String,
    params~ : Array[String],
    ctors~ : Array[TypeCtor],
    span~ : Span
  )
  InternalExportEnumDef(
    name~ : String,
    params~ : Array[String],
    ctors~ : Array[TypeCtor],
    span~ : Span
  )
  ExportTypeAlias(
    name~ : String,
    params~ : Array[String],
    target~ : Type,
    span~ : Span
  )
  InternalExportTypeAlias(
    name~ : String,
    params~ : Array[String],
    target~ : Type,
    span~ : Span
  )
  InternalTraitDef(
    name~ : String,
    supertraits~ : Array[String],
    open_impl~ : Bool,
    span~ : Span
  )
  Export(names~ : Array[String], span~ : Span)
  ReExport(spec~ : ImportSpec, source~ : ModuleRef, span~ : Span)
  StructDef(
    name~ : String,
    params~ : Array[String],
    fields~ : Array[StructField],
    span~ : Span
  )
  ExportStructDef(
    name~ : String,
    params~ : Array[String],
    fields~ : Array[StructField],
    span~ : Span
  )
  InternalExportStructDef(
    name~ : String,
    params~ : Array[String],
    fields~ : Array[StructField],
    span~ : Span
  )
} derive(Show, Eq)

///|
pub(all) struct LoopParam {
  name : String
  init : Expr
  span : Span
} derive(Show, Eq)

///|
pub(all) enum Expr {
  Int(value~ : Int64, span~ : Span)
  Float(value~ : Float, span~ : Span)
  Double(value~ : Double, span~ : Span)
  Bool(value~ : Bool, span~ : Span)
  Char(value~ : Char, span~ : Span)
  String(value~ : String, span~ : Span)
  Ident(name~ : String, span~ : Span)
  Placeholder(index~ : Int, span~ : Span) // _ placeholder for lambda shorthand
  Call(
    name~ : String,
    type_args~ : Array[Type],
    args~ : Array[CallArg],
    span~ : Span
  )
  Tuple(items~ : Array[Expr], span~ : Span)
  TupleIndex(expr~ : Expr, index~ : Int, span~ : Span)
  Record(fields~ : Array[RecordFieldExpr], span~ : Span)
  Array(items~ : Array[Expr], span~ : Span)
  Map(fields~ : Array[MapFieldExpr], span~ : Span)
  If(cond~ : Expr, then_body~ : Module, else_body~ : Module, span~ : Span)
  Block(body~ : Module, span~ : Span)
  Match(scrutinee~ : Expr, arms~ : Array[MatchArm], span~ : Span)
  ForIn(
    value_name~ : String,
    index_name~ : String?,
    iterable~ : Expr,
    body~ : Module,
    span~ : Span
  )
  Fn(
    type_params~ : Array[String],
    type_bounds~ : Map[String, Array[String]],
    params~ : Array[FuncParam],
    ret~ : Type?,
    effects~ : Array[EffectAtom],
    body~ : Module,
    span~ : Span
  )
  While(cond~ : Expr, body~ : Module, span~ : Span)
  Loop(params~ : Array[LoopParam], body~ : Module, span~ : Span)
  Break(value~ : Expr?, span~ : Span)
  Continue(args~ : Array[Expr], span~ : Span)
  Raise(value~ : Expr, span~ : Span)
  Yield(expr~ : Expr, span~ : Span)
  Handle(body~ : Module, arms~ : Array[MatchArm], span~ : Span)
  StructLit(
    name~ : String,
    type_args~ : Array[Type],
    fields~ : Array[RecordFieldExpr],
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
pub fn first_positional_expr(args : Array[CallArg]) -> Expr? {
  for arg in args {
    match arg.label {
      Some(_) => ()
      None => return Some(arg.expr)
    }
  }
  None
}

///|
pub fn Expr::span(self : Expr) -> Span {
  match self {
    Expr::Int(span~, ..)
    | Expr::Float(span~, ..)
    | Expr::Double(span~, ..)
    | Expr::Bool(span~, ..)
    | Expr::Char(span~, ..)
    | Expr::String(span~, ..)
    | Expr::Ident(span~, ..)
    | Expr::Placeholder(span~, ..)
    | Expr::Call(span~, ..)
    | Expr::Tuple(span~, ..)
    | Expr::TupleIndex(span~, ..)
    | Expr::Record(span~, ..)
    | Expr::Array(span~, ..)
    | Expr::Map(span~, ..)
    | Expr::If(span~, ..)
    | Expr::Block(span~, ..)
    | Expr::Match(span~, ..)
    | Expr::ForIn(span~, ..)
    | Expr::Fn(span~, ..)
    | Expr::While(span~, ..)
    | Expr::Loop(span~, ..)
    | Expr::Break(span~, ..)
    | Expr::Continue(span~, ..)
    | Expr::Raise(span~, ..)
    | Expr::Yield(span~, ..)
    | Expr::Handle(span~, ..)
    | Expr::StructLit(span~, ..) => span
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
    | Pat::Struct(span~, ..)
    | Pat::Int(span~, ..)
    | Pat::Float(span~, ..)
    | Pat::Double(span~, ..)
    | Pat::Bool(span~, ..)
    | Pat::Char(span~, ..)
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
    | Stmt::TraitDef(span~, ..)
    | Stmt::TraitImpl(span~, ..)
    | Stmt::Expr(span~, ..)
    | Stmt::Import(span~, ..)
    | Stmt::Test(span~, ..)
    | Stmt::Bench(span~, ..)
    | Stmt::LetMut(span~, ..)
    | Stmt::ExternLet(span~, ..)
    | Stmt::Assign(span~, ..)
    | Stmt::IndexAssign(span~, ..)
    | Stmt::LetPat(span~, ..)
    | Stmt::LetPatElse(span~, ..)
    | Stmt::ExportLet(span~, ..)
    | Stmt::InternalExportLet(span~, ..)
    | Stmt::ExportEnumDef(span~, ..)
    | Stmt::InternalExportEnumDef(span~, ..)
    | Stmt::ExportTypeAlias(span~, ..)
    | Stmt::InternalExportTypeAlias(span~, ..)
    | Stmt::InternalTraitDef(span~, ..)
    | Stmt::Export(span~, ..)
    | Stmt::ReExport(span~, ..)
    | Stmt::StructDef(span~, ..)
    | Stmt::ExportStructDef(span~, ..)
    | Stmt::InternalExportStructDef(span~, ..) => span
  }
}

///|
pub fn import_item_local_name(item : ImportItem) -> String {
  match item.rename {
    Some(rename_name) => rename_name
    None => item.name
  }
}
