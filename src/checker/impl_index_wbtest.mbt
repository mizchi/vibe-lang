// Tests for ADR-0051 Layer 2: `ImplIndex`.

///|
test "ImplIndex::impls_for returns registered impls" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.add_trait_impl("Eq", TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::Int,
  })
  let index = ImplIndex::of(env)
  let impls = index.impls_for("Eq")
  assert_eq(impls.length(), 1)
  assert_true(impls[0].target == @core.Type::Int)
}

///|
test "ImplIndex::traits_with_impls skips empty entries" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Hash", TraitDefInfo::defined_here([], false))
  env.add_trait_impl("Hash", TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::String,
  })
  let names = ImplIndex::of(env).traits_with_impls()
  assert_true(names.contains("Hash"))
  assert_false(names.contains("Eq"))
}

///|
test "ImplIndex::would_overlap rejects duplicate concrete impls" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.add_trait_impl("Eq", TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::Int,
  })
  let incoming : TraitImplDef = TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::Int,
  }
  assert_true(ImplIndex::of(env).would_overlap("Eq", incoming))
}

///|
test "ImplIndex::would_overlap allows disjoint concrete impls" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.add_trait_impl("Eq", TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::Int,
  })
  let incoming : TraitImplDef = TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::String,
  }
  assert_false(ImplIndex::of(env).would_overlap("Eq", incoming))
}

///|
test "ImplIndex::register_impl installs an impl through the canonical path" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  let span = @core.Span::empty(0)
  let index = ImplIndex::of(env)
  index.register_impl([], {}, "Eq", @core.Type::Int, span) catch {
    err => fail("register_impl unexpectedly failed: \{err.to_string()}")
  }
  assert_eq(index.impls_for("Eq").length(), 1)
}

///|
test "ImplIndex::register_impl rejects unknown trait" {
  let env = TypeEnv::new()
  let span = @core.Span::empty(0)
  let result : Result[Unit, TypeError] = try? ImplIndex::of(env).register_impl(
    [], {}, "DoesNotExist", @core.Type::Int, span,
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected register_impl to reject unknown trait")
  }
}

///|
test "ImplIndex::register_impl rejects overlap with existing impl" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  let span = @core.Span::empty(0)
  let index = ImplIndex::of(env)
  index.register_impl([], {}, "Eq", @core.Type::Int, span) catch {
    err => fail("first register_impl unexpectedly failed: \{err.to_string()}")
  }
  let second : Result[Unit, TypeError] = try? index.register_impl(
    [], {}, "Eq", @core.Type::Int, span,
  )
  match second {
    Err(_) => ()
    Ok(_) => fail("expected register_impl to reject overlapping impl")
  }
}
