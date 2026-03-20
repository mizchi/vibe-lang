///|
/// QueryEdge represents a dependency edge in the query graph.
/// It records which query/input was accessed and at what revision.
pub struct QueryEdge {
  /// Index of the ingredient (input or query) that was accessed
  ingredient_index : Int
  /// Key within the ingredient
  key_index : Int
  /// The revision at which the dependency was recorded (changed_at of the accessed value)
  changed_at : Revision
  /// Durability of the dependency
  durability : Durability
} derive(Eq, Show)

///|
/// ActiveQuery represents a query that is currently being executed.
/// It tracks dependencies as the query runs.
struct ActiveQuery {
  /// Index of the ingredient being executed
  ingredient_index : Int
  /// Key within the ingredient
  key_index : Int
  /// Dependencies recorded during execution
  edges : Array[QueryEdge]
  /// Maximum changed_at among all dependencies
  mut changed_at : Revision
  /// Minimum durability among all dependencies
  mut durability : Durability
}

///|
/// Create a new ActiveQuery.
pub fn ActiveQuery::new(ingredient_index : Int, key_index : Int) -> ActiveQuery {
  {
    ingredient_index,
    key_index,
    edges: [],
    changed_at: Revision::zero(),
    durability: Durability::High,
  }
}

///|
/// Add a dependency edge to the active query.
pub fn ActiveQuery::add_edge(
  self : ActiveQuery,
  ingredient_index : Int,
  key_index : Int,
  changed_at : Revision,
  durability : Durability,
) -> Unit {
  self.edges.push({ ingredient_index, key_index, changed_at, durability })
  self.changed_at = self.changed_at.max(changed_at)
  self.durability = self.durability.min(durability)
}

///|
/// Get the recorded edges.
pub fn ActiveQuery::get_edges(self : ActiveQuery) -> Array[QueryEdge] {
  self.edges
}

///|
/// Get the maximum changed_at revision.
pub fn ActiveQuery::get_changed_at(self : ActiveQuery) -> Revision {
  self.changed_at
}

///|
/// Get the minimum durability among all dependencies.
pub fn ActiveQuery::get_durability(self : ActiveQuery) -> Durability {
  self.durability
}

///|
/// Verifier function type: (key_index, revision) -> maybe_changed
priv struct Verifier((Int, Revision) -> Bool)

///|
/// Runtime manages the global state of the incremental computation system.
struct Runtime {
  /// Current revision counter
  mut current_revision : Revision
  /// Stack of currently executing queries (for dependency tracking)
  query_stack : Array[ActiveQuery]
  /// Last changed revision for each durability level
  /// Index 0 = Low, 1 = Medium, 2 = High
  durability_revisions : FixedArray[Revision]
  /// Verifier registry: ingredient_index -> verifier function
  verifiers : @hashmap.HashMap[Int, Verifier]
}

///|
/// Create a new Runtime.
pub fn Runtime::new() -> Runtime {
  {
    current_revision: Revision::new(1),
    query_stack: [],
    durability_revisions: [Revision::zero(), Revision::zero(), Revision::zero()],
    verifiers: @hashmap.new(),
  }
}

///|
/// Register a verifier for an ingredient.
pub fn Runtime::register_verifier(
  self : Runtime,
  ingredient_index : Int,
  verifier : (Int, Revision) -> Bool,
) -> Unit {
  self.verifiers.set(ingredient_index, Verifier(verifier))
}

///|
/// Check if an ingredient might have changed after a revision.
/// Returns true if changed or if no verifier is registered.
pub fn Runtime::maybe_changed_after(
  self : Runtime,
  ingredient_index : Int,
  key_index : Int,
  revision : Revision,
) -> Bool {
  match self.verifiers.get(ingredient_index) {
    Some(Verifier(verifier)) => verifier(key_index, revision)
    None => true // No verifier registered, assume changed
  }
}

///|
/// Get the current revision.
pub fn Runtime::current_revision(self : Runtime) -> Revision {
  self.current_revision
}

///|
/// Increment the revision (called when an input changes).
/// Updates the durability revision for the given durability level.
pub fn Runtime::increment_revision(
  self : Runtime,
  durability : Durability,
) -> Revision {
  self.current_revision = self.current_revision.next()
  // Update durability revision for this level and all lower levels
  let index = durability.to_index()
  for i = 0; i <= index; i = i + 1 {
    self.durability_revisions[i] = self.current_revision
  }
  self.current_revision
}

///|
/// Get the last changed revision for a durability level.
pub fn Runtime::last_changed_at(
  self : Runtime,
  durability : Durability,
) -> Revision {
  self.durability_revisions[durability.to_index()]
}

///|
/// Push a new active query onto the stack.
pub fn Runtime::push_query(
  self : Runtime,
  ingredient_index : Int,
  key_index : Int,
) -> Unit {
  self.query_stack.push(ActiveQuery::new(ingredient_index, key_index))
}

///|
/// Pop the active query from the stack and return its recorded edges, changed_at, and durability.
pub fn Runtime::pop_query(
  self : Runtime,
) -> (Array[QueryEdge], Revision, Durability)? {
  match self.query_stack.pop() {
    Some(q) => Some((q.get_edges(), q.get_changed_at(), q.get_durability()))
    None => None
  }
}

///|
/// Record a dependency in the currently executing query.
/// Returns true if there is an active query, false otherwise.
pub fn Runtime::record_dependency(
  self : Runtime,
  ingredient_index : Int,
  key_index : Int,
  changed_at : Revision,
  durability : Durability,
) -> Bool {
  match self.query_stack.last() {
    Some(q) => {
      q.add_edge(ingredient_index, key_index, changed_at, durability)
      true
    }
    None => false
  }
}

///|
/// Check if there is an active query on the stack.
pub fn Runtime::has_active_query(self : Runtime) -> Bool {
  not(self.query_stack.is_empty())
}

///|
/// Check if we are currently executing a specific query (for cycle detection).
pub fn Runtime::is_executing(
  self : Runtime,
  ingredient_index : Int,
  key_index : Int,
) -> Bool {
  for q in self.query_stack {
    if q.ingredient_index == ingredient_index && q.key_index == key_index {
      return true
    }
  }
  false
}

///|
/// Get the currently executing query (top of the stack).
/// Returns (ingredient_index, key_index) or None if no query is executing.
pub fn Runtime::get_current_query(self : Runtime) -> (Int, Int)? {
  match self.query_stack.last() {
    Some(q) => Some((q.ingredient_index, q.key_index))
    None => None
  }
}
