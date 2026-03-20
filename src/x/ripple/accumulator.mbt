///|
/// Accumulator collects values during query computation.
/// Useful for gathering diagnostics, warnings, or other side-effect data
/// without affecting the main computation result.
///
/// Example use cases:
/// - Collecting compiler warnings during type checking
/// - Gathering dependency information during module resolution
/// - Accumulating metrics during computation
pub struct Accumulator[V] {
  /// Unique index for this accumulator
  ingredient_index : Int
  /// Values accumulated per query execution
  /// Key: (query_ingredient_index, key_hash)
  /// Value: Array of accumulated values
  values : @hashmap.HashMap[(Int, Int), Array[V]]
}

///|
/// Create a new Accumulator with the given ingredient index.
pub fn[V] Accumulator::new(ingredient_index : Int) -> Accumulator[V] {
  { ingredient_index, values: @hashmap.new() }
}

///|
/// Get the ingredient index.
pub fn[V] Accumulator::get_index(self : Accumulator[V]) -> Int {
  self.ingredient_index
}

///|
/// Push a value to the accumulator in the context of the current query.
/// The value is associated with the currently executing query.
/// If no query is executing, the value is silently ignored.
pub fn[V] Accumulator::push(
  self : Accumulator[V],
  rt : Runtime,
  value : V,
) -> Unit {
  match rt.get_current_query() {
    Some((query_index, key_hash)) => {
      let key = (query_index, key_hash)
      match self.values.get(key) {
        Some(arr) => arr.push(value)
        None => self.values.set(key, [value])
      }
    }
    None => () // No active query, ignore
  }
}

///|
/// Collect all values accumulated for a specific query execution.
/// Returns an empty array if no values were accumulated.
pub fn[V] Accumulator::get(
  self : Accumulator[V],
  query_index : Int,
  key_hash : Int,
) -> Array[V] {
  match self.values.get((query_index, key_hash)) {
    Some(arr) => arr
    None => []
  }
}

///|
/// Collect all values accumulated for a query, given its Query instance and key.
pub fn[K : Hash, Q, V] Accumulator::get_for_query(
  self : Accumulator[V],
  query : Query[K, Q],
  key : K,
) -> Array[V] {
  ignore(query.compute)
  self.get(query.get_index(), key.hash())
}

///|
/// Collect all values accumulated for a CycleQuery, given its instance and key.
pub fn[K : Hash, Q, V] Accumulator::get_for_cycle_query(
  self : Accumulator[V],
  query : CycleQuery[K, Q],
  key : K,
) -> Array[V] {
  ignore(query.compute)
  self.get(query.get_index(), key.hash())
}

///|
/// Clear all accumulated values for a specific query execution.
/// Called when the query is invalidated and needs to be recomputed.
pub fn[V] Accumulator::clear(
  self : Accumulator[V],
  query_index : Int,
  key_hash : Int,
) -> Unit {
  self.values.remove((query_index, key_hash))
}

///|
/// Clear all accumulated values for a query, given its Query instance and key.
pub fn[K : Hash, Q, V] Accumulator::clear_for_query(
  self : Accumulator[V],
  query : Query[K, Q],
  key : K,
) -> Unit {
  ignore(query.compute)
  self.clear(query.get_index(), key.hash())
}

///|
/// Clear all accumulated values.
pub fn[V] Accumulator::clear_all(self : Accumulator[V]) -> Unit {
  // Remove all entries
  let keys_to_remove : Array[(Int, Int)] = []
  for entry in self.values.iter() {
    let (key, _) = entry
    keys_to_remove.push(key)
  }
  for key in keys_to_remove {
    self.values.remove(key)
  }
}

///|
/// Check if any values have been accumulated for a specific query execution.
pub fn[V] Accumulator::has_values(
  self : Accumulator[V],
  query_index : Int,
  key_hash : Int,
) -> Bool {
  match self.values.get((query_index, key_hash)) {
    Some(arr) => not(arr.is_empty())
    None => false
  }
}

///|
/// Get the count of accumulated values for a specific query execution.
pub fn[V] Accumulator::count(
  self : Accumulator[V],
  query_index : Int,
  key_hash : Int,
) -> Int {
  match self.values.get((query_index, key_hash)) {
    Some(arr) => arr.length()
    None => 0
  }
}

///|
/// Iterate over all accumulated values across all queries.
pub fn[V] Accumulator::iter(
  self : Accumulator[V],
) -> Iter[((Int, Int), Array[V])] {
  self.values.iter()
}
