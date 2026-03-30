///|
pub fn build_symbol_index(
  db : @runtime.VibeDb,
  paths : Array[String],
  skip_types? : Bool = false,
) -> @pipeline.SymbolIndex {
  ensure_hooks()
  let entries : Array[@pipeline.SymbolEntry] = []
  let seen_module_hashes : Map[String, Bool] = {}
  let empty_types = @checker.TypeEnv::new()
  for path in paths {
    match db.get_source(path) {
      Some(source) => {
        let module_hash = @core.content_address_hash_string(source)
        if seen_module_hashes.contains(module_hash) {
          continue
        }
        seen_module_hashes[module_hash] = true
      }
      None => ()
    }
    let ast = db.ast(path)
    let types = if skip_types { empty_types } else { db.types(path) }
    let per_module = @pipeline.build_symbol_index_for_module(path, ast, types)
    for entry in per_module.entries {
      entries.push(entry)
    }
  }
  @pipeline.build_symbol_index_from_entries(entries)
}
