// Tests for ADR-0051 Layer 1: `TraitGraph`.

///|
test "TraitGraph::is_subtrait reflexive and direct" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Ord", TraitDefInfo::defined_here(["Eq"], false))
  let g = TraitGraph::of(env)
  assert_true(g.is_subtrait("Eq", "Eq"))
  assert_true(g.is_subtrait("Ord", "Eq"))
  assert_false(g.is_subtrait("Eq", "Ord"))
}

///|
test "TraitGraph::is_subtrait transitive across deep hierarchy" {
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("C", TraitDefInfo::defined_here(["B"], false))
  env.set_trait_info("D", TraitDefInfo::defined_here(["C"], false))
  let g = TraitGraph::of(env)
  assert_true(g.is_subtrait("D", "A"))
  assert_true(g.is_subtrait("D", "B"))
  assert_true(g.is_subtrait("D", "C"))
  assert_false(g.is_subtrait("A", "D"))
}

///|
test "TraitGraph::super_closure returns transitive parents only" {
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("C", TraitDefInfo::defined_here(["B"], false))
  let supers = TraitGraph::of(env).super_closure("C")
  assert_true(supers.contains("B"))
  assert_true(supers.contains("A"))
  assert_false(supers.contains("C"))
}

///|
test "TraitGraph::has_cycle detects cycle introduced via import_trait" {
  // `register_trait_def` rejects self-reference, but `import_trait` rewrites
  // supertraits and can in principle introduce a cycle, so the graph layer
  // is responsible for detecting it.
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  // Force a cycle: A -> B -> A.
  env.set_trait_info("A", TraitDefInfo::imported(["B"], true))
  let g = TraitGraph::of(env)
  assert_true(g.has_cycle("A"))
  assert_true(g.has_cycle("B"))
}

///|
test "TraitGraph::supertraits returns one-hop parents only" {
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("C", TraitDefInfo::defined_here(["B"], false))
  let g = TraitGraph::of(env)
  let parents = g.supertraits("C")
  assert_eq(parents, ["B"])
}
