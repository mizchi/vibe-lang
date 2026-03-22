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

///|
/// Strip qualified prefix: "Color::Red" → "Red", "Red" → "Red"

///|
/// Resolved effect definition for type checker
pub(all) struct EffectDef_ {
  name : String
  params : Array[String]
  ops : Map[String, EffectOpSig]
} derive(Show, Eq)

///|
/// Resolved effect operation signature
pub(all) struct EffectOpSig {
  params : Array[Type]
  ret : Type
} derive(Show, Eq)

///|
pub fn strip_ctor_qualifier(name : String) -> String {
  for i = name.length() - 1; i >= 1; i = i - 1 {
    if name[i - 1].to_int() == ':'.to_int() && name[i].to_int() == ':'.to_int() {
      return name.unsafe_substring(start=i + 1, end=name.length())
    }
  }
  name
}

///|
pub fn is_ctor_name(name : String) -> Bool {
  if name.length() == 0 {
    false
  } else {
    // Type::method qualified names — check if the part after :: is uppercase
    if name.contains("::") {
      let stripped = strip_ctor_qualifier(name)
      return stripped.length() > 0 &&
        ({
          let c = stripped.to_array()[0]
          c >= 'A' && c <= 'Z'
        })
    }
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
pub(all) enum StringInterpPart {
  Lit(String)
  Expr(Expr)
} derive(Show, Eq)

///|
pub(all) struct MatchArm {
  pat : Pat
  cond : Expr?
  expr : Expr
  span : Span
} derive(Show, Eq)

///|
pub(all) struct TraitMethodSig {
  name : String
  params : Array[FuncParam]
  ret : Type
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
/// Effect operation: `Op(Args) -> ReturnType`
pub(all) struct EffectOp {
  name : String
  params : Array[Type]
  ret : Type
  span : Span
} derive(Show, Eq)

///|
/// Import item kind for explicit import namespaces.
pub(all) enum ImportKind {
  Value
  Type
  Struct
  Trait
  Effect
  Suberror
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
  Alias(name~ : String) // @types → Alias(name="types")
  PinnedPath(path~ : String, hash~ : String) // ./types#abc123 — path with hash pin
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
    methods~ : Array[TraitMethodSig],
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
    methods~ : Array[TraitMethodSig],
    open_impl~ : Bool,
    span~ : Span
  )
  Export(names~ : Array[String], span~ : Span)
  ReExport(spec~ : ImportSpec, source~ : ModuleRef, span~ : Span)
  AliasDecl(alias_name~ : String, source~ : ModuleRef, span~ : Span)
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
  EffectDef(
    name~ : String,
    params~ : Array[String],
    ops~ : Array[EffectOp],
    span~ : Span
  )
  ExportEffectDef(
    name~ : String,
    params~ : Array[String],
    ops~ : Array[EffectOp],
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
  /// String interpolation: `"hello ${name}"` → parts = [Lit("hello "), Expr(__to_string(name))]
  StringInterp(parts~ : Array[StringInterpPart], span~ : Span)
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
  Yield(expr~ : Expr, span~ : Span)
  Handle(body~ : Module, arms~ : Array[MatchArm], span~ : Span)
  StructLit(
    name~ : String,
    type_args~ : Array[Type],
    fields~ : Array[RecordFieldExpr],
    span~ : Span
  )
  Spread(expr~ : Expr, span~ : Span)
  /// perform Effect::Op(args) — algebraic effect operation invocation
  Perform(
    effect_name~ : String,
    op_name~ : String,
    args~ : Array[CallArg],
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
    | Expr::StringInterp(span~, ..)
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
    | Expr::Yield(span~, ..)
    | Expr::Handle(span~, ..)
    | Expr::StructLit(span~, ..)
    | Expr::Spread(span~, ..)
    | Expr::Perform(span~, ..) => span
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
    | Stmt::AliasDecl(span~, ..)
    | Stmt::StructDef(span~, ..)
    | Stmt::ExportStructDef(span~, ..)
    | Stmt::InternalExportStructDef(span~, ..)
    | Stmt::EffectDef(span~, ..)
    | Stmt::ExportEffectDef(span~, ..) => span
  }
}

///|
pub fn import_item_local_name(item : ImportItem) -> String {
  match item.rename {
    Some(rename_name) => rename_name
    None => item.name
  }
}
