///|
fn impl_def(target : @core.Type) -> TraitImplDef {
  TraitImplDef::{ type_params: [], type_bounds: {}, target }
}

///|
test "trait impl overlap precheck rejects disjoint concrete targets" {
  let left = impl_def(@core.Type::Named(name="UserId", args=[]))
  let right = impl_def(@core.Type::Int)
  assert_false(trait_impl_targets_may_overlap(left.target, right.target))
}

///|
test "trait impl overlap precheck keeps generic targets as maybe-overlap" {
  let left = TraitImplDef::{
    type_params: ["T"],
    type_bounds: {},
    target: @core.Type::Param("T"),
  }
  let right = impl_def(@core.Type::Named(name="UserId", args=[]))
  assert_true(trait_impl_targets_may_overlap(left.target, right.target))
}
