///|
/// Durability indicates how often a value is expected to change.
/// Higher durability means the value changes less frequently.
/// This is used to optimize cache invalidation.
pub(all) enum Durability {
  /// Low durability - changes frequently (e.g., user-edited files)
  Low
  /// Medium durability - changes occasionally
  Medium
  /// High durability - rarely changes (e.g., standard library)
  High
} derive(Eq, Compare, Show, Hash)

///|
/// Number of durability levels (for array indexing).
pub let durability_count : Int = 3

///|
/// Convert durability to array index.
pub fn Durability::to_index(self : Durability) -> Int {
  match self {
    Low => 0
    Medium => 1
    High => 2
  }
}

///|
/// Get the minimum of two durabilities.
pub fn Durability::min(self : Durability, other : Durability) -> Durability {
  match (self, other) {
    (Low, _) => Low
    (_, Low) => Low
    (Medium, _) => Medium
    (_, Medium) => Medium
    (High, High) => High
  }
}
