///|
test "normalize_builtin_name rewrites legacy map builder aliases" {
  assert_eq(normalize_builtin_name("map_builder"), "MapBuilder::new")
  assert_eq(normalize_builtin_name("map_builder_set"), "MapBuilder::set")
  assert_eq(normalize_builtin_name("map_builder_freeze"), "MapBuilder::freeze")
  assert_eq(normalize_builtin_name("map_get"), "map_get")
}

///|
test "is_map_builder_builtin_name accepts legacy and canonical names" {
  assert_true(is_map_builder_builtin_name("map_builder"))
  assert_true(is_map_builder_builtin_name("MapBuilder::new"))
  assert_true(is_map_builder_builtin_name("map_builder_set"))
  assert_true(is_map_builder_builtin_name("MapBuilder::set"))
  assert_false(is_map_builder_builtin_name("map_get"))
}
