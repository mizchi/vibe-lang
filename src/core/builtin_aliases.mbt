///|
pub fn normalize_builtin_name(name : String) -> String {
  if name == "map_builder" {
    "MapBuilder::new"
  } else if name == "map_builder_set" {
    "MapBuilder::set"
  } else if name == "map_builder_freeze" {
    "MapBuilder::freeze"
  } else {
    name
  }
}

///|
pub fn is_map_builder_builtin_name(name : String) -> Bool {
  match normalize_builtin_name(name) {
    "MapBuilder::new" | "MapBuilder::set" | "MapBuilder::freeze" => true
    _ => false
  }
}
