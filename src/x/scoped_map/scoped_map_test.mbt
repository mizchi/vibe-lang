///|
test "new and set/get" {
  let m : ScopedMap[Int] = ScopedMap::new()
  m["x"] = 1
  m["y"] = 2
  assert_eq(m.get("x"), Some(1))
  assert_eq(m.get("y"), Some(2))
  assert_eq(m.get("z"), None)
}

///|
test "fork inherits parent" {
  let parent : ScopedMap[Int] = ScopedMap::new()
  parent["a"] = 10
  let child = parent.fork()
  assert_eq(child.get("a"), Some(10))
  // child write doesn't affect parent
  child["a"] = 20
  assert_eq(child.get("a"), Some(20))
  assert_eq(parent.get("a"), Some(10))
}

///|
test "fork child adds own" {
  let parent : ScopedMap[Int] = ScopedMap::new()
  parent["a"] = 1
  let child = parent.fork()
  child["b"] = 2
  assert_eq(child.get("a"), Some(1))
  assert_eq(child.get("b"), Some(2))
  assert_eq(parent.get("b"), None)
}

///|
test "contains walks parent chain" {
  let p : ScopedMap[Int] = ScopedMap::new()
  p["x"] = 1
  let c = p.fork()
  assert_true(c.contains("x"))
  assert_false(c.contains("y"))
}

///|
test "remove only affects own" {
  let p : ScopedMap[Int] = ScopedMap::new()
  p["x"] = 1
  let c = p.fork()
  // promote x to child's own via get
  let _ = c.get("x")
  c.remove("x")
  // still accessible from parent
  assert_eq(c.get("x"), Some(1))
}

///|
test "copy flattens parent chain" {
  let p : ScopedMap[Int] = ScopedMap::new()
  p["a"] = 1
  let c = p.fork()
  c["b"] = 2
  let flat = c.copy()
  assert_eq(flat.get("a"), Some(1))
  assert_eq(flat.get("b"), Some(2))
  assert_true(flat.parent is None)
}

///|
test "copy own overrides parent" {
  let p : ScopedMap[Int] = ScopedMap::new()
  p["x"] = 1
  let c = p.fork()
  c["x"] = 2
  let flat = c.copy()
  assert_eq(flat.get("x"), Some(2))
}

///|
test "merge_up_or_self pushes to parent" {
  let p : ScopedMap[Int] = ScopedMap::new()
  p["a"] = 1
  let c = p.fork()
  c["b"] = 2
  c["a"] = 10
  let merged = c.merge_up_or_self()
  assert_eq(merged.get("a"), Some(10))
  assert_eq(merged.get("b"), Some(2))
  assert_true(merged.parent is None)
}

///|
test "from_map" {
  let m : Map[String, Int] = {}
  m["k"] = 42
  let sm = ScopedMap::from_map(m)
  assert_eq(sm.get("k"), Some(42))
}

///|
test "lazy promotion caches in own" {
  let p : ScopedMap[Int] = ScopedMap::new()
  p["x"] = 1
  let c = p.fork()
  // first get promotes to own
  assert_eq(c.get("x"), Some(1))
  assert_true(c.own.contains("x"))
}

///|
test "deep chain" {
  let a : ScopedMap[Int] = ScopedMap::new()
  a["x"] = 1
  let b = a.fork()
  b["y"] = 2
  let c = b.fork()
  c["z"] = 3
  assert_eq(c.get("x"), Some(1))
  assert_eq(c.get("y"), Some(2))
  assert_eq(c.get("z"), Some(3))
}
