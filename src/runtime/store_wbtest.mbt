///|
fn wbtest_restore_store_env(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "Runtime::fork_for_test preserves configured loop fuel" {
  let prev = @sys.get_env_var("VIBE_LOOP_FUEL")
  @sys.set_env_var("VIBE_LOOP_FUEL", "222222")
  defer wbtest_restore_store_env("VIBE_LOOP_FUEL", prev)

  let rt = Runtime::new(@capability.CapabilitySet::new())
  let forked = rt.fork_for_test()
  assert_eq(rt.loop_fuel, 222222)
  assert_eq(forked.loop_fuel, 222222)
}
