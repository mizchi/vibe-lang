///| Shell-specific normalize helpers (native only)

///|
fn normalize_source_text_for_shell(source : String) -> Result[String, String] {
  normalize_source_text_with_entry_names_internal(source, [], true)
}

///|
fn normalize_source_text_with_entry_names_for_shell(
  source : String,
  entry_names : Array[String],
) -> Result[String, String] {
  normalize_source_text_with_entry_names_internal(source, entry_names, true)
}
