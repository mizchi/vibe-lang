///|
/// HashedModule wraps a Module with a structural hash for efficient equality comparison.
/// This enables ripple's backdate optimization when only whitespace changes.
pub struct HashedModule {
  ast : @core.Module
  hash : Int
}

///|
pub fn HashedModule::new(m : @core.Module) -> HashedModule {
  { ast: m, hash: m.structural_hash() }
}

///|
/// Equality based on structural hash, not full AST comparison
pub impl Eq for HashedModule with fn equal(self, other) {
  self.hash == other.hash
}

///|
pub fn HashedModule::unwrap(self : HashedModule) -> @core.Module {
  self.ast
}
