// incr - Incremental computation library for MoonBit
//
// This library provides a framework for incremental computation,
// inspired by Rust's salsa framework. It automatically memoizes
// computation results and tracks dependencies, so that when inputs
// change, only the affected computations are rerun.
//
// Core concepts:
// - Revision: Monotonically increasing counter for tracking changes
// - Input: External input values that can be changed
// - Query: Memoized computations that depend on inputs or other queries
// - Database: Facade that manages all state
//
// Usage example:
// ```
// let db = Database::new()
// let rt = db.runtime()
//
// let files : Input[String, String] = db.input()
// let parse : Query[String, AST] = db.query(fn(rt, path) {
//   let content = files.get(rt, path).unwrap()
//   // ... parse logic
// })
//
// files.set(rt, "main.mbt", "...")
// let ast = parse.fetch(rt, "main.mbt")
// ```
