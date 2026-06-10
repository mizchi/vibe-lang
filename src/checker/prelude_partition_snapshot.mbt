///|
/// Issue #402: static snapshot of the prelude value-stmt partition.
///
/// `_prelude_partition_value_stmts` builds a dependency graph + runs a fixpoint
/// over the prelude value defs to split them into "core" vs "builtin-dependent".
/// A fresh selfhost compiler process used to load a disk snapshot and re-split
/// the prelude by decoded names, but the one-shot bundle path still paid the
/// file read + binary decode. The builtin-dependent set is tiny and changes
/// only when `prelude_source` / partition logic changes, so keep it as a source
/// snapshot and assert it against the computed partition in whitebox tests.
fn prelude_static_builtin_value_name(name : String) -> Bool {
  match name {
    "add"
    | "sub"
    | "mul"
    | "div"
    | "eq"
    | "lt"
    | "assert"
    | "assert_true"
    | "assert_eq"
    | "to_string"
    | "iter_length"
    | "iter_get"
    | "Map::iter_length"
    | "Map::iter_get"
    | "Array::map"
    | "Array::fold"
    | "Array::filter"
    | "Array::foreach"
    | "Array::concat"
    | "Array::any"
    | "Array::all"
    | "Array::find"
    | "array_find_index"
    | "array_find_last_index"
    | "array_contains_by"
    | "Array::reverse"
    | "Array::sort"
    | "Array::contains"
    | "Array::join"
    | "string_concat_all"
    | "Map::get_or"
    | "Map::map"
    | "Map::filter"
    | "Map::size"
    | "Map::foreach"
    | "Map::entries"
    | "Map::merge"
    | "where" => true
    _ => false
  }
}

///|
fn split_prelude_value_stmts_by_static_snapshot(
  ast : @core.Module,
) -> (Array[@core.Stmt], Array[@core.Stmt]) {
  let core_stmts : Array[@core.Stmt] = []
  let builtin_stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) =>
        if prelude_static_builtin_value_name(name) {
          builtin_stmts.push(stmt)
        } else {
          core_stmts.push(stmt)
        }
      None => ()
    }
  }
  (core_stmts, builtin_stmts)
}
