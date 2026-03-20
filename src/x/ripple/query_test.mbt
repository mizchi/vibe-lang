///|
test "Query verifier only invalidates the touched key" {
  let db = Database::new()
  let rt = db.runtime()
  let inputs : Input[String, Int] = db.input()
  inputs.register(rt)
  let mut call_count = 0
  let parity : Query[String, Int] = db.query(fn(rt, key) {
    call_count = call_count + 1
    match inputs.get(rt, key) {
      Some(value) => value % 2
      None => 0
    }
  })
  parity.register(rt)
  let mut sum_count = 0
  let sum : Query[String, Int] = db.query(fn(rt, _key) {
    sum_count = sum_count + 1
    parity.fetch(rt, "a") + parity.fetch(rt, "b")
  })
  sum.register(rt)
  inputs.set(rt, "a", 1) |> ignore
  inputs.set(rt, "b", 3) |> ignore
  assert_eq(sum.fetch(rt, "sum"), 2)
  assert_eq(call_count, 2)
  assert_eq(sum_count, 1)
  let sum_changed_1 = match sum.changed_at("sum") {
    Some(rev) => rev.get()
    None => fail("expected sum changed_at")
  }
  inputs.set(rt, "b", 5) |> ignore
  assert_eq(sum.fetch(rt, "sum"), 2)
  assert_eq(call_count, 3)
  assert_eq(sum_count, 1)
  let sum_changed_2 = match sum.changed_at("sum") {
    Some(rev) => rev.get()
    None => fail("expected sum changed_at after update")
  }
  assert_eq(sum_changed_2, sum_changed_1)
}
