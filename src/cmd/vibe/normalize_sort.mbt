///|
fn normalize_sort_stmts(
  stmts : Array[@vibe_core.Stmt],
) -> Array[@vibe_core.Stmt] {
  @vibe_core.canonical_sort_stmts(stmts)
}

///|
fn normalize_stmt_def_name(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Let(name~, ..)
    | @vibe_core.Stmt::ExportLet(name~, ..)
    | @vibe_core.Stmt::InternalExportLet(name~, ..)
    | @vibe_core.Stmt::ExternLet(name~, ..)
    | @vibe_core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn normalize_stmt_group(stmt : @vibe_core.Stmt) -> NormalizeStmtGroup {
  match stmt {
    @vibe_core.Stmt::Import(..)
    | @vibe_core.Stmt::ReExport(..)
    | @vibe_core.Stmt::AliasDecl(..) => NormalizeStmtGroup::Use
    @vibe_core.Stmt::TypeAlias(..)
    | @vibe_core.Stmt::ExportTypeAlias(..)
    | @vibe_core.Stmt::InternalExportTypeAlias(..)
    | @vibe_core.Stmt::EnumDef(..)
    | @vibe_core.Stmt::ExportEnumDef(..)
    | @vibe_core.Stmt::InternalExportEnumDef(..)
    | @vibe_core.Stmt::StructDef(..)
    | @vibe_core.Stmt::ExportStructDef(..)
    | @vibe_core.Stmt::InternalExportStructDef(..) =>
      NormalizeStmtGroup::TypeDecl
    @vibe_core.Stmt::TraitDef(..)
    | @vibe_core.Stmt::InternalTraitDef(..)
    | @vibe_core.Stmt::TraitImpl(..) => NormalizeStmtGroup::TraitDecl
    @vibe_core.Stmt::Let(..)
    | @vibe_core.Stmt::ExportLet(..)
    | @vibe_core.Stmt::InternalExportLet(..)
    | @vibe_core.Stmt::ExternLet(..)
    | @vibe_core.Stmt::LetMut(..)
    | @vibe_core.Stmt::Assign(..)
    | @vibe_core.Stmt::IndexAssign(..)
    | @vibe_core.Stmt::LetPat(..)
    | @vibe_core.Stmt::LetPatElse(..)
    | @vibe_core.Stmt::Expr(..) => NormalizeStmtGroup::FnDef
    @vibe_core.Stmt::Test(..)
    | @vibe_core.Stmt::Bench(..)
    | @vibe_core.Stmt::Export(..) => NormalizeStmtGroup::Other
  }
}
