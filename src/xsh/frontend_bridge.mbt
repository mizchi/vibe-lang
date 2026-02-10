///|
pub using @frontend {
  desugar_method_calls,
  desugar_xshell_commands,
  desugar_xshell_commands_with_notes,
}

///|
pub using @frontend {type MonoifyResult}

///|
pub using @frontend {monoify_module}

///|
pub using @frontend {
  dce_module,
  dce_module_with_entry_names,
  dce_module_for_tests,
}

///|
pub using @frontend {type SymbolKind}

///|
pub using @frontend {type SymbolEntry}

///|
pub using @frontend {type SymbolIndex}

///|
pub using @frontend {symbol_kind_name}

///|
pub using @frontend {build_symbol_index_for_module}

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
pub using @frontend {symbol_index_to_lsif_lines}
