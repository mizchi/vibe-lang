///|
/// Structural hash for AST nodes (ignoring Span)
/// Used for incremental computation to detect semantic changes

///|
/// Hash a Module structurally (ignoring spans)
pub fn Module::structural_hash(self : Module) -> Int {
  let mut h = 0x4d6f6475 // "Modu"
  for stmt in self.stmts {
    h = combine_hash(h, stmt.structural_hash())
  }
  h
}

///|
/// Hash a Stmt structurally
pub fn Stmt::structural_hash(self : Stmt) -> Int {
  match self {
    Stmt::Let(rec~, name~, expr~, ..) => {
      let mut h = 0x4c657400 // "Let\0"
      h = combine_hash(h, if rec { 1 } else { 0 })
      h = combine_hash(h, name.hash())
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Stmt::LetMut(name~, expr~, ..) => {
      let mut h = 0x4c65744d // "LetM"
      h = combine_hash(h, name.hash())
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Stmt::LetPat(pat~, expr~, ..) => {
      let mut h = 0x4c657450 // "LetP"
      h = combine_hash(h, pat.structural_hash())
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Stmt::Assign(name~, expr~, ..) => {
      let mut h = 0x41737369 // "Assi"
      h = combine_hash(h, name.hash())
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Stmt::IndexAssign(target~, index~, value~, ..) => {
      let mut h = 0x49647841 // "IdxA"
      h = combine_hash(h, target.structural_hash())
      h = combine_hash(h, index.structural_hash())
      h = combine_hash(h, value.structural_hash())
      h
    }
    Stmt::EnumDef(name~, params~, ctors~, ..) => {
      let mut h = 0x456e756d // "Enum"
      h = combine_hash(h, name.hash())
      for p in params {
        h = combine_hash(h, p.hash())
      }
      for c in ctors {
        h = combine_hash(h, c.structural_hash())
      }
      h
    }
    Stmt::TypeAlias(name~, params~, target~, ..) => {
      let mut h = 0x54797065 // "Type"
      h = combine_hash(h, name.hash())
      for p in params {
        h = combine_hash(h, p.hash())
      }
      h = combine_hash(h, target.structural_hash())
      h
    }
    Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, ..) => {
      let mut h = 0x54726169 // "Trai"
      h = combine_hash(h, name.hash())
      for supertrait in supertraits {
        h = combine_hash(h, supertrait.hash())
      }
      h = combine_hash(h, open_impl.hash())
      h = combine_hash(h, exported.hash())
      h
    }
    Stmt::TraitImpl(type_params~, type_bounds~, trait_name~, target~, ..) => {
      let mut h = 0x54696d70 // "Timp"
      h = combine_hash(h, trait_name.hash())
      h = combine_hash(h, target.structural_hash())
      for tp in type_params {
        h = combine_hash(h, tp.hash())
      }
      let keys = type_bounds.keys().collect()
      keys.sort()
      for key in keys {
        h = combine_hash(h, key.hash())
        match type_bounds.get(key) {
          Some(bounds) =>
            for bound in bounds {
              h = combine_hash(h, bound.hash())
            }
          None => ()
        }
      }
      h
    }
    Stmt::Expr(expr~, ..) => {
      let mut h = 0x45787072 // "Expr"
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Stmt::Import(spec~, source~, ..) => {
      let mut h = 0x496d706f // "Impo"
      h = combine_hash(h, spec.structural_hash())
      h = combine_hash(h, source.structural_hash())
      h
    }
    Stmt::Test(name~, body~, ..) => {
      let mut h = 0x54657374 // "Test"
      h = combine_hash(h, name.map(fn(n) { n.hash() }).unwrap_or(0))
      h = combine_hash(h, body.structural_hash())
      h
    }
    Stmt::Bench(name~, body~, ..) => {
      let mut h = 0x42656e63 // "Benc"
      h = combine_hash(h, name.map(fn(n) { n.hash() }).unwrap_or(0))
      h = combine_hash(h, body.structural_hash())
      h
    }
    Stmt::ExportLet(rec~, name~, expr~, ..) => {
      let mut h = 0x45784c65 // "ExLe"
      h = combine_hash(h, if rec { 1 } else { 0 })
      h = combine_hash(h, name.hash())
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Stmt::ExportEnumDef(name~, params~, ctors~, ..) => {
      let mut h = 0x45784564 // "ExEd"
      h = combine_hash(h, name.hash())
      for p in params {
        h = combine_hash(h, p.hash())
      }
      for c in ctors {
        h = combine_hash(h, c.structural_hash())
      }
      h
    }
    Stmt::ExportTypeAlias(name~, params~, target~, ..) => {
      let mut h = 0x45785479 // "ExTy"
      h = combine_hash(h, name.hash())
      for p in params {
        h = combine_hash(h, p.hash())
      }
      h = combine_hash(h, target.structural_hash())
      h
    }
    Stmt::Export(names~, ..) => {
      let mut h = 0x4578706f // "Expo"
      for n in names {
        h = combine_hash(h, n.hash())
      }
      h
    }
    Stmt::ReExport(names~, source~, ..) => {
      let mut h = 0x52654578 // "ReEx"
      for n in names {
        h = combine_hash(h, n.hash())
      }
      h = combine_hash(h, source.structural_hash())
      h
    }
    Stmt::StructDef(name~, params~, fields~, ..) => {
      let mut h = 0x53747275 // "Stru"
      h = combine_hash(h, name.hash())
      for p in params {
        h = combine_hash(h, p.hash())
      }
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
    Stmt::ExportStructDef(name~, params~, fields~, ..) => {
      let mut h = 0x45785374 // "ExSt"
      h = combine_hash(h, name.hash())
      for p in params {
        h = combine_hash(h, p.hash())
      }
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
  }
}

///|
/// Hash an Expr structurally
pub fn Expr::structural_hash(self : Expr) -> Int {
  match self {
    Expr::Int(value~, ..) => combine_hash(0x496e7400, value.to_int())
    Expr::Float(value~, ..) =>
      combine_hash(0x466c6f61, value.reinterpret_as_int())
    Expr::Double(value~, ..) => {
      let bits = value.reinterpret_as_int64()
      combine_hash(0x446f7562, bits.to_int())
    }
    Expr::Bool(value~, ..) =>
      combine_hash(0x426f6f6c, if value { 1 } else { 0 })
    Expr::Char(value~, ..) => combine_hash(0x43686172, value.to_int())
    Expr::String(value~, ..) => combine_hash(0x53747269, value.hash())
    Expr::Ident(name~, ..) => combine_hash(0x4964656e, name.hash())
    Expr::Placeholder(index~, ..) => combine_hash(0x506c6163, index)
    Expr::Call(name~, type_args~, args~, ..) => {
      let mut h = 0x43616c6c // "Call"
      h = combine_hash(h, name.hash())
      for t in type_args {
        h = combine_hash(h, t.structural_hash())
      }
      for a in args {
        h = combine_hash(h, a.structural_hash())
      }
      h
    }
    Expr::Tuple(items~, ..) => {
      let mut h = 0x5475706c // "Tupl"
      for i in items {
        h = combine_hash(h, i.structural_hash())
      }
      h
    }
    Expr::TupleIndex(expr~, index~, ..) => {
      let mut h = 0x54706978 // "Tpix"
      h = combine_hash(h, expr.structural_hash())
      h = combine_hash(h, index)
      h
    }
    Expr::Record(fields~, ..) => {
      let mut h = 0x5265636f // "Reco"
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
    Expr::Array(items~, ..) => {
      let mut h = 0x41727261 // "Arra"
      for i in items {
        h = combine_hash(h, i.structural_hash())
      }
      h
    }
    Expr::Map(fields~, ..) => {
      let mut h = 0x4d617000 // "Map\0"
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
    Expr::If(cond~, then_body~, else_body~, ..) => {
      let mut h = 0x49660000 // "If\0\0"
      h = combine_hash(h, cond.structural_hash())
      h = combine_hash(h, then_body.structural_hash())
      h = combine_hash(h, else_body.structural_hash())
      h
    }
    Expr::Block(body~, ..) => {
      let mut h = 0x426c6f63 // "Bloc"
      h = combine_hash(h, body.structural_hash())
      h
    }
    Expr::Match(scrutinee~, arms~, ..) => {
      let mut h = 0x4d617463 // "Matc"
      h = combine_hash(h, scrutinee.structural_hash())
      for a in arms {
        h = combine_hash(h, a.structural_hash())
      }
      h
    }
    Expr::Do(body~, ..) => {
      let mut h = 0x446f0000 // "Do\0\0"
      h = combine_hash(h, body.structural_hash())
      h
    }
    Expr::Try(try_body~, catch_body~, ..) => {
      let mut h = 0x54727900 // "Try\0"
      h = combine_hash(h, try_body.structural_hash())
      h = combine_hash(h, catch_body.structural_hash())
      h
    }
    Expr::Fn(type_params~, type_bounds~, params~, ret~, effects~, body~, ..) => {
      let mut h = 0x466e0000 // "Fn\0\0"
      for tp in type_params {
        h = combine_hash(h, tp.hash())
      }
      let keys = type_bounds.keys().collect()
      keys.sort()
      for key in keys {
        h = combine_hash(h, key.hash())
        match type_bounds.get(key) {
          Some(bounds) =>
            for bound in bounds {
              h = combine_hash(h, bound.hash())
            }
          None => ()
        }
      }
      for p in params {
        h = combine_hash(h, p.structural_hash())
      }
      h = combine_hash(h, ret.map(fn(r) { r.structural_hash() }).unwrap_or(0))
      for e in effects {
        h = combine_hash(h, e.structural_hash())
      }
      h = combine_hash(h, body.structural_hash())
      h
    }
    Expr::While(cond~, body~, ..) => {
      let mut h = 0x5768696c // "Whil"
      h = combine_hash(h, cond.structural_hash())
      h = combine_hash(h, body.structural_hash())
      h
    }
    Expr::Break(..) => 0x42726561 // "Brea"
    Expr::Continue(..) => 0x436f6e74 // "Cont"
    Expr::Raise(value~, ..) => {
      let mut h = 0x52616973 // "Rais"
      h = combine_hash(h, value.structural_hash())
      h
    }
    Expr::Await(expr~, ..) => {
      let mut h = 0x41776169 // "Awai"
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Expr::Yield(expr~, ..) => {
      let mut h = 0x5969656c // "Yiel"
      h = combine_hash(h, expr.structural_hash())
      h
    }
    Expr::StructLit(name~, type_args~, fields~, ..) => {
      let mut h = 0x53747243 // "StrC"
      h = combine_hash(h, name.hash())
      for t in type_args {
        h = combine_hash(h, t.structural_hash())
      }
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
  }
}

///|
/// Hash a Type structurally
pub fn Type::structural_hash(self : Type) -> Int {
  match self {
    Type::Int => 0x496e7400
    Type::Float => 0x466c6f74
    Type::Double => 0x446f7562
    Type::Bool => 0x426f6f6c
    Type::Char => 0x43686172
    Type::String => 0x53747267
    Type::Unit => 0x556e6974
    Type::Path => 0x50617468
    Type::Never => 0x4e657665
    Type::Named(name~, args~) => {
      let mut h = 0x4e616d65
      h = combine_hash(h, name.hash())
      for a in args {
        h = combine_hash(h, a.structural_hash())
      }
      h
    }
    Type::Param(name) => combine_hash(0x50617261, name.hash())
    Type::Var(id) => combine_hash(0x56617200, id)
    Type::Tuple(items) => {
      let mut h = 0x5475706c
      for i in items {
        h = combine_hash(h, i.structural_hash())
      }
      h
    }
    Type::Record(fields) => {
      let mut h = 0x5265636f
      for name, ty in fields {
        h = combine_hash(h, name.hash())
        h = combine_hash(h, ty.structural_hash())
      }
      h
    }
    Type::Array(inner) => combine_hash(0x41727261, inner.structural_hash())
    Type::Map(inner) => combine_hash(0x4d617000, inner.structural_hash())
    Type::ArrayBuilder(inner) =>
      combine_hash(0x41724275, inner.structural_hash())
    Type::MapBuilder(inner) => combine_hash(0x4d614275, inner.structural_hash())
    Type::Variant(ctors) => {
      let mut h = 0x56617269
      for name, ty in ctors {
        h = combine_hash(h, name.hash())
        h = combine_hash(h, ty.structural_hash())
      }
      h
    }
    Type::Func(params~, ret~, effects~) => {
      let mut h = 0x46756e63
      for p in params {
        h = combine_hash(h, p.structural_hash())
      }
      h = combine_hash(h, ret.structural_hash())
      for e in effects {
        h = combine_hash(h, e.structural_hash())
      }
      h
    }
  }
}

///|
/// Hash a Pat structurally
pub fn Pat::structural_hash(self : Pat) -> Int {
  match self {
    Pat::Wildcard(..) => 0x57696c64
    Pat::Bind(name~, ..) => combine_hash(0x42696e64, name.hash())
    Pat::Ctor(name~, args~, ..) => {
      let mut h = 0x43746f72
      h = combine_hash(h, name.hash())
      for a in args {
        h = combine_hash(h, a.structural_hash())
      }
      h
    }
    Pat::Tuple(items~, ..) => {
      let mut h = 0x5475706c
      for i in items {
        h = combine_hash(h, i.structural_hash())
      }
      h
    }
    Pat::Record(fields~, ..) => {
      let mut h = 0x5265636f
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
    Pat::Int(value~, ..) => combine_hash(0x496e7400, value.to_int())
    Pat::Float(value~, ..) =>
      combine_hash(0x466c6f61, value.reinterpret_as_int())
    Pat::Double(value~, ..) => {
      let bits = value.reinterpret_as_int64()
      combine_hash(0x446f7562, bits.to_int())
    }
    Pat::Bool(value~, ..) => combine_hash(0x426f6f6c, if value { 1 } else { 0 })
    Pat::Char(value~, ..) => combine_hash(0x43686172, value.to_int())
    Pat::String(value~, ..) => combine_hash(0x53747269, value.hash())
    Pat::Or(pats~, ..) => {
      let mut h = 0x4f720000
      for p in pats {
        h = combine_hash(h, p.structural_hash())
      }
      h
    }
    Pat::Struct(name~, fields~, ..) => {
      let mut h = 0x53747250 // "StrP"
      h = combine_hash(h, name.hash())
      for f in fields {
        h = combine_hash(h, f.structural_hash())
      }
      h
    }
  }
}

///|
fn RecordFieldPat::structural_hash(self : RecordFieldPat) -> Int {
  let mut h = self.name.hash()
  h = combine_hash(h, self.pat.structural_hash())
  h
}

///|
fn RecordFieldExpr::structural_hash(self : RecordFieldExpr) -> Int {
  let mut h = self.name.hash()
  h = combine_hash(h, self.expr.structural_hash())
  h
}

///|
fn MapFieldExpr::structural_hash(self : MapFieldExpr) -> Int {
  let mut h = self.key.hash()
  h = combine_hash(h, self.expr.structural_hash())
  h
}

///|
fn CallArg::structural_hash(self : CallArg) -> Int {
  let mut h = self.label.map(fn(l) { l.hash() }).unwrap_or(0)
  h = combine_hash(h, self.expr.structural_hash())
  h
}

///|
fn MatchArm::structural_hash(self : MatchArm) -> Int {
  let mut h = self.pat.structural_hash()
  h = combine_hash(h, self.cond.map(fn(c) { c.structural_hash() }).unwrap_or(0))
  h = combine_hash(h, self.expr.structural_hash())
  h
}

///|
fn TypeCtor::structural_hash(self : TypeCtor) -> Int {
  let mut h = self.name.hash()
  for a in self.args {
    h = combine_hash(h, a.structural_hash())
  }
  h
}

///|
fn StructField::structural_hash(self : StructField) -> Int {
  let mut h = self.name.hash()
  h = combine_hash(h, self.ty.structural_hash())
  h
}

///|
fn FuncParam::structural_hash(self : FuncParam) -> Int {
  let mut h = self.name.hash()
  h = combine_hash(h, self.label.structural_hash())
  h = combine_hash(h, self.ty.structural_hash())
  for bound in self.bounds {
    h = combine_hash(h, bound.hash())
  }
  h
}

///|
fn ParamLabel::structural_hash(self : ParamLabel) -> Int {
  match self {
    ParamLabel::Positional => 0
    ParamLabel::Required => 1
    ParamLabel::Optional => 2
  }
}

///|
fn EffectAtom::structural_hash(self : EffectAtom) -> Int {
  match self {
    EffectAtom::Const(name) => combine_hash(0x436f6e73, name.hash())
    EffectAtom::Var(name) => combine_hash(0x56617200, name.hash())
  }
}

///|
fn ImportSpec::structural_hash(self : ImportSpec) -> Int {
  let mut h = 0x496d7053 // "ImpS"
  for item in self.items {
    h = combine_hash(h, item.structural_hash())
  }
  h
}

///|
fn ImportItem::structural_hash(self : ImportItem) -> Int {
  let mut h = self.kind.structural_hash()
  h = combine_hash(h, self.name.hash())
  h = combine_hash(h, self.rename.map(fn(r) { r.hash() }).unwrap_or(0))
  h
}

///|
fn ImportKind::structural_hash(self : ImportKind) -> Int {
  match self {
    ImportKind::Value => 0
    ImportKind::Type => 1
    ImportKind::Trait => 2
    ImportKind::Module => 3
  }
}

///|
fn ModuleRef::structural_hash(self : ModuleRef) -> Int {
  match self {
    ModuleRef::Path(path~) => combine_hash(0x50617468, path.hash())
    ModuleRef::Hash(hash~) => combine_hash(0x48617368, hash.hash())
    ModuleRef::Version(name~) => combine_hash(0x56657273, name.hash())
    ModuleRef::Symbol(name~) => combine_hash(0x53796d62, name.hash())
  }
}

///|
/// Combine two hash values using a simple mixing function
fn combine_hash(h1 : Int, h2 : Int) -> Int {
  // FNV-1a inspired mixing
  let prime = 16777619
  (h1 ^ h2) * prime
}
