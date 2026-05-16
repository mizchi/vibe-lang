///|
test "TraitDefInfo constructors preserve ownership and hierarchy" {
  let imported = TraitDefInfo::imported(["Eq", "Hash"], true)
  assert_true(imported.origin == TraitOrigin::Imported)
  @debug.assert_eq(imported.supertraits, ["Eq", "Hash"])
  assert_true(imported.open_impl)

  let defined_here = TraitDefInfo::defined_here(["Eq"], false)
  assert_true(defined_here.origin == TraitOrigin::DefinedHere)
  @debug.assert_eq(defined_here.supertraits, ["Eq"])
  assert_false(defined_here.open_impl)

  let seeded = TraitDefInfo::prelude_seeded()
  assert_true(seeded.origin == TraitOrigin::PreludeSeed)
  @debug.assert_eq(seeded.supertraits, [])
  assert_false(seeded.open_impl)
}

///|
test "TraitDefInfo::allows_impl_here follows ownership instead of ad-hoc bool checks" {
  assert_true(TraitDefInfo::defined_here([], false).allows_impl_here())
  assert_true(TraitDefInfo::prelude_seeded().allows_impl_here())
  assert_true(TraitDefInfo::imported([], true).allows_impl_here())
  assert_false(TraitDefInfo::imported([], false).allows_impl_here())
}

///|
test "TypeEnv::trait_accepts_impl_here uses trait ownership model" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::prelude_seeded())
  env.set_trait_info("LocalEq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("RemoteEq", TraitDefInfo::imported([], false))
  env.set_trait_info("RemoteOpenEq", TraitDefInfo::imported([], true))

  assert_true(env.trait_accepts_impl_here("Eq"))
  assert_true(env.trait_accepts_impl_here("LocalEq"))
  assert_false(env.trait_accepts_impl_here("RemoteEq"))
  assert_true(env.trait_accepts_impl_here("RemoteOpenEq"))
  assert_false(env.trait_accepts_impl_here("Missing"))
}

///|
test "TypeEnv::import_trait rewrites ownership without losing openness or hierarchy" {
  let env = TypeEnv::new()
  env.import_trait("OrdAlias", TraitDefInfo::defined_here(["Eq"], true), [
    "EqAlias",
  ])
  assert_true(
    env.get_trait_info("OrdAlias") ==
    Some(TraitDefInfo::imported(["EqAlias"], true)),
  )

  env.import_trait("SeededEq", TraitDefInfo::prelude_seeded(), [])
  assert_true(
    env.get_trait_info("SeededEq") == Some(TraitDefInfo::imported([], false)),
  )
}
