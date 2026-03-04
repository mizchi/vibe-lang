///|
pub using @frontend {
  desugar_method_calls,
  desugar_vibe_commands,
  desugar_vibe_commands_with_notes,
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
pub using @frontend {
  symbol_kind_name,
  symbol_kind_from_name,
  symbol_entry_from_kind_name,
}

///|
pub using @frontend {
  build_symbol_index_for_module,
  build_symbol_index_from_entries,
}

///|
pub using @frontend {symbol_index_to_lsif_lines}
