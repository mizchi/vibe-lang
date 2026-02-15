///|
pub using @pipeline {
  desugar_method_calls,
  desugar_vibe_commands,
  desugar_vibe_commands_with_notes,
}

///|
pub using @pipeline {type MonoifyResult}

///|
pub using @pipeline {monoify_module}

///|
pub using @pipeline {
  dce_module,
  dce_module_with_entry_names,
  dce_module_for_tests,
}

///|
pub using @pipeline {type SymbolKind}

///|
pub using @pipeline {type SymbolEntry}

///|
pub using @pipeline {type SymbolIndex}

///|
pub using @pipeline {symbol_kind_name}

///|
pub using @pipeline {build_symbol_index_for_module}

///|
pub fn build_symbol_index(db : VibeDb, paths : Array[String]) -> SymbolIndex {
  let entries : Array[SymbolEntry] = []
  for path in paths {
    let ast = db.ast(path)
    let types = db.types(path)
    let per_module = build_symbol_index_for_module(path, ast, types)
    for entry in per_module.entries {
      entries.push(entry)
    }
  }
  @pipeline.build_symbol_index_from_entries(entries)
}

///|
pub using @pipeline {symbol_index_to_lsif_lines}
