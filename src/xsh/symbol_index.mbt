///|
pub type SymbolKind = @frontend.SymbolKind

///|
pub type SymbolEntry = @frontend.SymbolEntry

///|
pub type SymbolIndex = @frontend.SymbolIndex

///|
pub fn symbol_kind_name(kind : SymbolKind) -> String {
  @frontend.symbol_kind_name(kind)
}

///|
pub fn build_symbol_index_for_module(
  path : String,
  ast : @core.Module,
  types : @checker.TypeEnv,
) -> SymbolIndex {
  @frontend.build_symbol_index_for_module(path, ast, types)
}

///|
pub fn build_symbol_index(db : XshDb, paths : Array[String]) -> SymbolIndex {
  let entries : Array[SymbolEntry] = []
  for path in paths {
    let ast = db.ast(path)
    let types = db.types(path)
    let per_module = build_symbol_index_for_module(path, ast, types)
    for entry in per_module.entries {
      entries.push(entry)
    }
  }
  @frontend.build_symbol_index_from_entries(entries)
}

///|
pub fn symbol_index_to_lsif_lines(
  index : SymbolIndex,
  source_of : (String) -> String?,
) -> Array[String] {
  @frontend.symbol_index_to_lsif_lines(index, source_of)
}
