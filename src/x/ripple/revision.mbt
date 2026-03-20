///|
/// Revision represents a monotonically increasing counter.
/// Each time an input changes, the revision is incremented.
/// This is the core mechanism for tracking changes in the incremental computation system.
/// Using newtype struct for zero-cost abstraction.
pub struct Revision(Int) derive(Eq, Compare, Show, Hash)

///|
/// Create a new Revision with value 0 (initial state).
pub fn Revision::zero() -> Revision {
  Revision(0)
}

///|
/// Create a new Revision from an integer value.
pub fn Revision::new(value : Int) -> Revision {
  Revision(value)
}

///|
/// Get the integer value of the revision.
pub fn Revision::get(self : Revision) -> Int {
  self.0
}

///|
/// Create the next revision (increment by 1).
pub fn Revision::next(self : Revision) -> Revision {
  Revision(self.0 + 1)
}

///|
/// Check if this revision is after another revision.
pub fn Revision::is_after(self : Revision, other : Revision) -> Bool {
  self.0 > other.0
}

///|
/// Check if this revision is at or after another revision.
pub fn Revision::is_at_or_after(self : Revision, other : Revision) -> Bool {
  self.0 >= other.0
}

///|
/// Return the maximum of two revisions.
pub fn Revision::max(self : Revision, other : Revision) -> Revision {
  if self.0 >= other.0 {
    self
  } else {
    other
  }
}
